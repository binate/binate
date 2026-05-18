bootstrap Go's lexer rejects literals beyond int64-max via strconv.ParseInt(..., 64); fixing it isn't in scope (the boot-mode tooling is intentionally limited to int64-fitting literals).
