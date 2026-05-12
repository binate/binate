pkg/lint is consumed only by cmd/bnlint, which is no longer required to be bootstrap-runnable — bnc + its dep tree is the only bootstrap-supported surface.
