module infoflow.analysis.ift.ift_graph;

import std.container.dlist;
import std.typecons;
import std.traits;
import std.array : appender, array;
import std.range;
import std.algorithm;
import infoflow.analysis.common;
import std.algorithm.iteration : map, filter, fold;
import core.atomic : atomicOp;
import std.exception : enforce;

import infoflow.models;

template IFTAnalysisGraph(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    enum IFTGraphNodeMemSize = __traits(classInstanceSize, IFTGraphNode);

    final class IFTGraph {
        /// graph vertices/nodes
        IFTGraphNode[] nodes;

        /// graph edges
        IFTGraphEdge[] edges;

        /// cache by commit id
        alias NodeCacheSet = IFTGraphNode[InfoNode];
        NodeCacheSet[ulong] _nodes_by_commit_cache;

        pragma(inline, true) {
            private IFTGraphNode _find_cached(ulong commit_id, InfoNode node) {
                if (commit_id in _nodes_by_commit_cache) {
                    if (node in _nodes_by_commit_cache[commit_id]) {
                        // cache hit
                        return _nodes_by_commit_cache[commit_id][node];
                    }
                }

                // cache miss
                return null;
            }

            private void _store_cached(ulong commit_id, InfoNode node, IFTGraphNode vert) {
                // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
                _nodes_by_commit_cache[commit_id][node] = vert;
            }

            private void _clear_cached(ulong commit_id) {
                _nodes_by_commit_cache[commit_id] = null;
            }

            private void _remove_cached(ulong commit_id, InfoNode node) {
                _nodes_by_commit_cache[commit_id].remove(node);
            }
        }

        void add_node(IFTGraphNode node) {
            // ensure no duplicate exists
            enforce(!_find_cached(node.info_view.commit_id, node.info_view.node),
                format("attempt to add duplicate node: %s", node));

            nodes ~= node;
            // cache it
            // _nodes_by_commit_cache[node.info_view.commit_id][node.info_view.node] = node;
            _store_cached(node.info_view.commit_id, node.info_view.node, node);
        }

        IFTGraphNode find_in_cache(ulong commit_id, InfoNode node) {
            return _find_cached(commit_id, node);
        }

        IFTGraphNode find_node(ulong commit_id, InfoNode node) {
            // see if we can find it in the cache
            IFTGraphNode cached = _find_cached(commit_id, node);
            if (cached !is null)
                return cached;

            // find with linear search
            for (long i = 0; i < nodes.length; i++) {
                if (nodes[i].info_view.commit_id == commit_id && nodes[i].info_view.node == node) {
                    // cache it
                    _store_cached(commit_id, node, nodes[i]);
                    return nodes[i];
                }
            }

            // not found
            return null;
        }

        IFTGraphNode get_node_ix(ulong index) {
            return nodes[index];
        }

        bool[IFTGraphEdge] _edge_cache;

        pragma(inline, true) {
            private void _store_edge_cache(IFTGraphEdge edge, bool value) {
                _edge_cache[edge] = value;
            }

            private bool _find_edge_cache(IFTGraphEdge edge) {
                if (edge in _edge_cache)
                    return _edge_cache[edge];
                return false;
            }
        }

        alias GraphEdges = IFTGraphEdge[];
        GraphEdges[IFTGraphNode] _node_neighbors_from_cache;
        GraphEdges[IFTGraphNode] _node_neighbors_to_cache;

        void add_edge(IFTGraphEdge edge) {
            // // ensure no duplicate exists
            // enforce(!_find_edge_cache(edge), format("attempt to add duplicate edge: %s", edge));

            edges ~= edge;

            // cache it
            _store_edge_cache(edge, true);
            
            // add to the neighbor lists
            if (edge.src !in _node_neighbors_from_cache) {
                _node_neighbors_from_cache[edge.src] = [];
            }
            _node_neighbors_from_cache[edge.src] ~= edge;
            if (edge.dst !in _node_neighbors_to_cache) {
                _node_neighbors_to_cache[edge.dst] = [];
            }
            _node_neighbors_to_cache[edge.dst] ~= edge;
        }

        bool edge_exists(IFTGraphEdge edge, bool cache_only = false) {
            if (_find_edge_cache(edge))
                return true;
            
            if (cache_only) return false;
            
            // linear search
            for (long i = 0; i < edges.length; i++) {
                if (edges[i] == edge) {
                    // cache it
                    _store_edge_cache(edge, true);
                    return true;
                }
            }

            // not found
            return false;
        }

        IFTGraphEdge get_edge_ix(ulong index) {
            return edges[index];
        }

        private auto filter_edges_from(IFTGraphNode node) {
            return filter!(edge => edge.src == node)(edges);
        }

        private auto filter_edges_to(IFTGraphNode node) {
            return filter!(edge => edge.dst == node)(edges);
        }

        void rebuild_neighbors_cache() {
            import std.parallelism: parallel;

            // clear the caches
            _node_neighbors_from_cache.clear();
            _node_neighbors_to_cache.clear();

            // for each node, build a list of neighbors, pointing to and from
            // for (size_t i = 0; i < nodes.length; i++) {
            //     IFTGraphNode node = nodes[i];

            //     _node_neighbors_from_cache[node] = filter_edges_from(node).array;
            //     _node_neighbors_to_cache[node] = filter_edges_to(node).array;
            // }
            foreach (i, node; parallel(nodes)) {
                auto edges_from = filter_edges_from(node).array;
                auto edges_to = filter_edges_to(node).array;

                synchronized (this) {
                    _node_neighbors_from_cache[node] = edges_from;
                    _node_neighbors_to_cache[node] = edges_to;
                }
            }

            _node_neighbors_from_cache.rehash();
            _node_neighbors_to_cache.rehash();
        }

        IFTGraphEdge[] get_edges_from(IFTGraphNode node) {
            // check cache
            if (node in _node_neighbors_from_cache)
                return _node_neighbors_from_cache[node];
            return filter_edges_from(node).array;
        }

        IFTGraphEdge[] get_edges_to(IFTGraphNode node) {
            if (node in _node_neighbors_to_cache)
                return _node_neighbors_to_cache[node];
            return filter_edges_to(node).array;
        }

        bool remove_node(IFTGraphNode node) {
            // delete the node from the list of nodes
            auto node_ix = nodes.countUntil(node);
            if (node_ix == -1)
                return false;
            // enforce(this.nodes[node_ix] == node, "node mismatch");
            this.nodes = this.nodes.remove(node_ix);
            // delete the node from the cache
            _remove_cached(node.info_view.commit_id, node.info_view.node);

            delete_edges_touching(node);

            return true;
        }

        void delete_edges_touching(IFTGraphNode node) {
            // // delete all edges to and from the node
            // auto edges_from = get_edges_from(node);
            // auto edges_to = get_edges_to(node);
            // foreach (i, edge; edges_from) {
            //     remove_edge(edge);
            // }
            // foreach (i, edge; edges_to) {
            //     remove_edge(edge);
            // }

            // stupid method: scan all edges and delete anything referencing this node
            foreach (edge; this.edges.filter!(edge => edge.src == node || edge.dst == node)) {
                remove_edge(edge);
            }
        }

        bool remove_edge(IFTGraphEdge edge) {
            // delete the edge from the list of edges
            // auto edge_count_prev = edges.length;
            auto edge_ix = edges.countUntil(edge);
            if (edge_ix == -1)
                return false;
            this.edges = this.edges.remove(edge_ix);

            // delete the edge from the caches
            _store_edge_cache(edge, false);
            _edge_cache.remove(edge);

            // auto old_from_nb_length = _node_neighbors_from_cache[edge.src].length;

            // delete the edge from the neighbor lists
            auto from_neighbors = _node_neighbors_from_cache[edge.src];
            auto to_neighbors = _node_neighbors_to_cache[edge.dst];
            _node_neighbors_from_cache[edge.src] = from_neighbors.remove(from_neighbors.countUntil(edge));
            _node_neighbors_to_cache[edge.dst] = to_neighbors.remove(to_neighbors.countUntil(edge));

            // auto edge_count_diff = edge_count_prev - edges.length;
            // enforce(edge_count_diff == 1, format("edge count diff: %d", edge_count_diff));
            // auto from_nb_length_diff = old_from_nb_length - _node_neighbors_from_cache[edge.src].length;
            // enforce(from_nb_length_diff == 1, format("from nb length diff: %d", from_nb_length_diff));

            return true;
        }

        @property size_t num_verts() {
            return nodes.length;
        }

        @property size_t num_edges() {
            return edges.length;
        }
    }

    struct IFTGraphEdge {
        /// source node
        IFTGraphNode src;
        /// destination node
        IFTGraphNode dst;
        // /// edge direction
        // bool is_forward = true;

        string toString() const {
            return format("%s -> %s", src, dst);
            // return format("%s %s %s", src, is_forward ? "->" : "<-", dst);
        }
    }

    final class IFTGraphNode {
        /// the information as it existed in a point in time
        InfoView info_view;
        Flags flags = Flags.None;

        this(InfoView info_view) {
            this.info_view = info_view;
        }

        enum Flags {
            None = 0x0,
            Final = 1 << 0,
            Deterministic = 1 << 1,
            Inner = 1 << 2,
            Propagated = 1 << 3,
            Reserved3 = 1 << 4,
            Reserved4 = 1 << 5,
            Reserved5 = 1 << 6,
            Reserved6 = 1 << 7,
            Reserved7 = 1 << 8,
        }

        override string toString() const {
            import std.string : format;
            import std.conv : to;
            import std.array : appender, array;

            auto sb = appender!string;

            auto node_str = to!string(info_view.node);
            sb ~= format("#%s %s", info_view.commit_id, node_str);

            return sb.array;
        }
    }
}
