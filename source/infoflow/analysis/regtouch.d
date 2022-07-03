module analyzers.regtouch;

import infoflow.analysis.common;

template RegTouchAnalysis(TRegWord, TMemWord, TRegSet, int register_count) {
    alias TInfoLog = InfoLog!(TRegWord, TMemWord, TRegSet, register_count);
    alias TBaseAnalysis = BaseAnalysis!(TRegWord, TMemWord, TRegSet, register_count);
    mixin(TInfoLog.GenAliases!("TInfoLog"));

    class RegTouchAnalyzer : TBaseAnalysis.BaseAnalyzer {
        this(CommitTrace commit_trace, bool parallelized) {
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
                for (auto j = 0; j < commit.reg_ids.length; j++) {
                    auto scan_reg_id = commit.reg_ids[j];
                    if (scan_reg_id == reg_id) {
                        // we found a write
                        return i;
                    }
                }
            }

            return -1;
        }

        override void analyze() {
        }

        override void dump_analysis() {
        }

        override void dump_summary() {
        }
    }
}