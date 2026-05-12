pkg/asm/parse parses asm source text; consumed only by cmd/bnas, which is no longer required to be bootstrap-runnable.  bnc emits structured asm via pkg/asm/aarch64 etc. and never parses asm text.
