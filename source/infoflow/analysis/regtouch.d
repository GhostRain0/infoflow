module analyzers.regtouch;

import std.algorithm: map, filter;
import std.range: array;
import std.algorithm.comparison;

import infoflow.analysis.common;

template RegTouchAnalysis(TRegWord, TMemWord, TRegSet) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    class RegTouchAnalyzer : TBaseAnalysis.BaseAnalyzer {
        int window_size = 8192;
        int window_slide = 512;

        this(CommitTrace commit_trace, bool parallelized = false) {
            super(commit_trace, parallelized);
        }

        long find_commit_reg_read(long from_commit, TRegSet reg_id, bool search_forward) {
            auto delta = search_forward ? 1 : -1;

            // go through commits until we find one that touches the register
            for (auto i = from_commit; i >= 0 && i < trace.commits.length; i += delta) {
                auto commit = &trace.commits[i];
                
                // when searching for a read, we are looking for the reg to be in the commit sources
                for (auto j = 0; j < commit.sources.length; j++) {
                    auto source = &commit.sources[j];

                    if ((source.type & InfoType.Register) > 0) {
                        if (source.data == reg_id) {
                            // we found a read
                            return i;
                        }
                    }
                }
            }

            return -1;
        }

        long find_commit_reg_write(long from_commit, TRegSet reg_id, bool search_forward) {
            auto delta = search_forward ? 1 : -1;

            // go through commits until we find one that touches the register
            for (auto i = from_commit; i >= 0 && i < trace.commits.length; i += delta) {
                auto commit = &trace.commits[i];
                
                // when searching for a read, we are looking for the reg to be in the dest regs
                // for (auto j = 0; j < commit.reg_ids.length; j++) {
                //     auto scan_reg_id = commit.reg_ids[j];
                //     if (scan_reg_id == reg_id) {
                //         // we found a write
                //         return i;
                //     }
                // }
                for (auto j = 0; j < commit.effects.length; j++) {
                    auto effect = commit.effects[j];
                    if (effect.type & InfoType.Register && effect.data == reg_id) {
                        // we found a write
                        return i;
                    }
                }
            }

            return -1;
        }

        override void analyze() {
            // slide window through the commits
            for (long window_start = 0; window_start < trace.commits.length - window_size; window_start += window_slide) {
                long window_end = min(window_start + window_size, trace.commits.length);
                if (window_start >= window_end) break;

                // analyze the window
                analyze_window(window_start, window_end);
            }
        }

        struct RegFreeRange {
            long start;
            long end;
        }

        struct RegUsage {
            long commit_last_read;
            long commit_last_write;

            RegFreeRange[] free_ranges;
        }

        void analyze_window(long window_start, long window_end) {
            auto window_commits = trace.commits[window_start..window_end];

            mixin(LOG_INFO!(`format("analyzing window [%d, %d]", window_start, window_end)`));

            RegUsage[TRegSet] reg_usage;

            // initialize the reg usage
            import std.traits: EnumMembers;
            auto reg_ids = [EnumMembers!TRegSet];
            foreach (reg_id; reg_ids) {
                reg_usage[reg_id] = RegUsage(-1, -1);
            }

            // go through the window
            for (auto i = 0; i < window_commits.length; i++) {
                auto commit = &window_commits[i];

                // for each reg
                foreach (reg_id; reg_ids) {
                    bool reg_was_read = false;
                    bool reg_was_written = false;

                    // check if the reg is read (sources)
                    for (auto j = 0; j < commit.sources.length; j++) {
                        auto source = &commit.sources[j];
                        if ((source.type & InfoType.Register) > 0 && source.data == reg_id) {
                            reg_usage[reg_id].commit_last_read = i + window_start;
                            reg_was_read = true;

                            mixin(LOG_TRACE!(`format(" reg %s read at commit %d", reg_id, i + window_start)`));
                        }
                    }

                    // check if the reg is written (effects)
                    for (auto j = 0; j < commit.effects.length; j++) {
                        auto effect = commit.effects[j];
                        if ((effect.type & InfoType.Register) > 0 && effect.data == reg_id) {
                            reg_usage[reg_id].commit_last_write = i + window_start;
                            reg_was_written = true;

                            mixin(LOG_TRACE!(`format(" reg %s written at commit %d", reg_id, i + window_start)`)); 
                        }
                    }

                    // now update our analysis of when the reg is "free"
                    // a register is free in the window between its last read to its last write
                    if (reg_was_written) {
                        // ensure it was read within the window
                        if (reg_usage[reg_id].commit_last_read < window_start) continue;
                        // check the distance between the last read and last write
                        auto read_write_dist = reg_usage[reg_id].commit_last_write - reg_usage[reg_id].commit_last_read;
                        enum MIN_USEFUL_DIST = 2;
                        if (read_write_dist <= MIN_USEFUL_DIST) continue;

                        // there was a useful write/read distance
                        // add a free range
                        auto free_range = RegFreeRange(
                            reg_usage[reg_id].commit_last_read + 1,
                            reg_usage[reg_id].commit_last_write - 1);
                        reg_usage[reg_id].free_ranges ~= free_range;

                        // log
                        mixin(LOG_TRACE!(`format("  reg %s free range [%d, %d]", reg_id, free_range.start, free_range.end)`));
                    }
                }
            }
        }

        void dump_analysis() {
        }

        void dump_summary() {
        }
    }
}