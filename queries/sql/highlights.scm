; ─── Comments ────────────────────────────────────────────────────────────────

(comment) @comment
(block_comment) @comment.block

; ─── Literals ────────────────────────────────────────────────────────────────

(string) @string
(blob) @string.special
(number) @number
(boolean) @boolean
(null) @constant.builtin
(parameter) @variable.parameter

; ─── Identifiers ─────────────────────────────────────────────────────────────

; Column name in a qualified or unqualified column reference
(column_ref column: (identifier) @variable.member)

; Aliases (SELECT foo AS bar, FROM t AS t1, etc.)
(select_item alias: (identifier) @variable)
(from_clause alias: (identifier) @variable)
(update_statement alias: (identifier) @variable)
(delete_statement alias: (identifier) @variable)

; CTE name
(cte name: (identifier) @function)

; ─── Functions ───────────────────────────────────────────────────────────────

(function_call function: (function_name) @function.call)

; CAST is function-like
"CAST" @function.builtin

; ─── Types ───────────────────────────────────────────────────────────────────

(data_type) @type

; Typed string literals: DATE 'val', TIMESTAMP 'val', etc.
(typed_string type: _ @type)

; Interval literals: INTERVAL '3' DAY, INTERVAL '1-2' YEAR TO MONTH, etc.
"INTERVAL" @keyword
"YEAR"     @keyword
"MONTH"    @keyword
"DAY"      @keyword
"HOUR"     @keyword
"MINUTE"   @keyword
"SECOND"   @keyword

; ─── Operators ───────────────────────────────────────────────────────────────

(binary_expression operator: _ @operator)
(unary_expression operator: _ @operator)

"::" @operator   ; PostgreSQL cast operator
"="  @operator
"!=" @operator
"<>" @operator
"<"  @operator
">"  @operator
"<=" @operator
">=" @operator
"<=>" @operator

; ─── Keyword operators ───────────────────────────────────────────────────────

"AND"       @keyword.operator
"OR"        @keyword.operator
"XOR"       @keyword.operator
"NOT"       @keyword.operator
"PRIOR"     @keyword.operator
"IN"        @keyword.operator
"BETWEEN"   @keyword.operator
"LIKE"      @keyword.operator
"ILIKE"     @keyword.operator
"GLOB"      @keyword.operator
"REGEXP"    @keyword.operator
"SIMILAR"   @keyword.operator
"IS"        @keyword.operator
"EXISTS"    @keyword.operator
"UNION"     @keyword.operator
"INTERSECT" @keyword.operator
"EXCEPT"    @keyword.operator

; ─── Conditional ─────────────────────────────────────────────────────────────

"CASE" @keyword.conditional
"WHEN" @keyword.conditional
"THEN" @keyword.conditional
"ELSE" @keyword.conditional
"END"  @keyword.conditional

; ─── RETURNING ───────────────────────────────────────────────────────────────

"RETURNING" @keyword.return

; ─── Oracle hierarchical query keywords ─────────────────────────────────────

"CONNECT"  @keyword
"NOCYCLE"  @keyword
"SIBLINGS" @keyword

; ─── DQL keywords ────────────────────────────────────────────────────────────

"SELECT"    @keyword
"FROM"      @keyword
"WHERE"     @keyword
"GROUP"     @keyword
"BY"        @keyword
"HAVING"    @keyword
"ORDER"     @keyword
"LIMIT"     @keyword
"OFFSET"    @keyword
"FETCH"     @keyword
"NEXT"      @keyword
"ROW"       @keyword
"ROWS"      @keyword
"ONLY"      @keyword
"TOP"       @keyword
"PERCENT"   @keyword
"WITH"      @keyword
"RECURSIVE" @keyword
"AS"        @keyword
"DISTINCT"  @keyword
"ALL"       @keyword
"UNIQUE"    @keyword
"INTO"      @keyword
"ASC"       @keyword
"DESC"      @keyword
"NULLS"     @keyword
"FIRST"     @keyword
"LAST"      @keyword

; ─── DML keywords ────────────────────────────────────────────────────────────

"INSERT"  @keyword
"UPDATE"  @keyword
"DELETE"  @keyword
"SET"     @keyword
"VALUES"  @keyword
"DEFAULT" @keyword
"DO"      @keyword
"NOTHING" @keyword

; ON CONFLICT
"CONFLICT" @keyword
"REPLACE"  @keyword
"IGNORE"   @keyword
"ABORT"    @keyword
"FAIL"     @keyword

; ─── DDL keywords ────────────────────────────────────────────────────────────

"CREATE"         @keyword
"TABLE"          @keyword
"VIEW"           @keyword
"INDEX"          @keyword
"ALTER"          @keyword
"DROP"           @keyword
"TRUNCATE"       @keyword
"COLUMN"         @keyword
"CONSTRAINT"     @keyword
"PRIMARY"        @keyword
"KEY"            @keyword
"FOREIGN"        @keyword
"REFERENCES"     @keyword
"CHECK"          @keyword
"GENERATED"      @keyword
"ALWAYS"         @keyword
"STORED"         @keyword
"VIRTUAL"        @keyword
"IDENTITY"       @keyword
"AUTOINCREMENT"  @keyword
"AUTO_INCREMENT" @keyword
"MODIFY"         @keyword
"RENAME"         @keyword
"TO"             @keyword
"ADD"            @keyword
"CASCADE"        @keyword
"RESTRICT"       @keyword
"WITHOUT"        @keyword
"ROWID"          @keyword
"STRICT"         @keyword
"TEMPORARY"      @keyword
"TEMP"           @keyword
"GLOBAL"         @keyword
"LOCAL"          @keyword
"IF"             @keyword
"NO"             @keyword
"ACTION"         @keyword
"MATCH"          @keyword
"DEFERRABLE"     @keyword
"INITIALLY"      @keyword
"DEFERRED"       @keyword
"IMMEDIATE"      @keyword
"MATERIALIZED"   @keyword
"TYPE"           @keyword
"DATA"           @keyword
"DATABASE"       @keyword
"SCHEMA"         @keyword
"SEQUENCE"       @keyword

; ─── Join keywords ───────────────────────────────────────────────────────────

"JOIN"    @keyword
"INNER"   @keyword
"OUTER"   @keyword
"LEFT"    @keyword
"RIGHT"   @keyword
"FULL"    @keyword
"NATURAL" @keyword
"CROSS"   @keyword
"LATERAL" @keyword
"ON"      @keyword
"USING"   @keyword

; ─── MSSQL table hints ───────────────────────────────────────────────────────

"NOLOCK"              @keyword
"READUNCOMMITTED"     @keyword
"READCOMMITTED"       @keyword
"READCOMMITTEDLOCK"   @keyword
"REPEATABLEREAD"      @keyword
"SNAPSHOT"            @keyword
"UPDLOCK"             @keyword
"XLOCK"               @keyword
"TABLOCK"             @keyword
"TABLOCKX"            @keyword
"PAGLOCK"             @keyword
"ROWLOCK"             @keyword
"NOWAIT"              @keyword
"READPAST"            @keyword
"FORCESEEK"           @keyword
"HOLDLOCK"            @keyword

; ─── Transaction keywords ────────────────────────────────────────────────────

"BEGIN"        @keyword
"START"        @keyword
"WORK"         @keyword
"TRANSACTION"  @keyword
"TRAN"         @keyword
"COMMIT"       @keyword
"ROLLBACK"     @keyword
"SAVEPOINT"    @keyword
"RELEASE"      @keyword
"ISOLATION"    @keyword
"LEVEL"        @keyword
"UNCOMMITTED"  @keyword
"COMMITTED"    @keyword
"REPEATABLE"   @keyword
"SERIALIZABLE" @keyword
"EXCLUSIVE"    @keyword
"CONTINUE"     @keyword
"RESTART"      @keyword

; ─── Explain / Call ──────────────────────────────────────────────────────────

"EXPLAIN" @keyword
"QUERY"   @keyword
"PLAN"    @keyword
"FOR"     @keyword
"ANALYZE" @keyword
"VERBOSE" @keyword
"COSTS"   @keyword
"SETTINGS" @keyword
"BUFFERS" @keyword
"FORMAT"  @keyword
"CALL"    @keyword
"EXEC"    @keyword
"EXECUTE" @keyword

; ─── PSQL \copy ──────────────────────────────────────────────────────────────

"\\"       @keyword
"COPY"     @keyword
"PROGRAM"  @keyword
"STDIN"    @keyword
"STDOUT"   @keyword
"PSTDIN"   @keyword
"PSTDOUT"  @keyword
(copy_option name: (identifier) @attribute)

; ─── Ordered-set aggregates ──────────────────────────────────────────────────

"WITHIN" @keyword

; ─── Window / Frame keywords ─────────────────────────────────────────────────

"WINDOW"    @keyword
"PARTITION" @keyword
"OVER"      @keyword
"FILTER"    @keyword
"ARRAY"     @keyword
"UNBOUNDED" @keyword
"PRECEDING" @keyword
"FOLLOWING" @keyword
"CURRENT"   @keyword
"RANGE"     @keyword
"GROUPS"    @keyword
"EXCLUDE"   @keyword
"OTHERS"    @keyword
"TIES"      @keyword
"SESSION"   @keyword

; IS expression constants (outside of literal context)
"UNKNOWN" @constant.builtin

; ─── Punctuation ─────────────────────────────────────────────────────────────

";" @punctuation.delimiter
"," @punctuation.delimiter
"." @punctuation.delimiter
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
