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

; Recursive-CTE cycle detection: the marked columns and the pseudo-columns the
; clause introduces (CYCLE id SET is_cycle TO 'Y' DEFAULT 'N' USING path).
(cycle_clause column: (identifier) @variable.member)
(cycle_clause mark: (identifier) @variable.member)
(cycle_clause path: (identifier) @variable.member)

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
"CYCLE"     @keyword
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
"COMMENT"        @keyword
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

; ─── COMMENT ON ──────────────────────────────────────────────────────────────

; The commented object; for COLUMN this is the dotted `schema.table.column`.
(comment_statement name: (table_ref) @variable)

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

; ─── SQLcl LOAD ──────────────────────────────────────────────────────────────

"LOAD"            @keyword
"DELIMITER"       @keyword
"QUOTE"           @keyword
"SKIP"            @keyword
"BATCH"           @keyword
"ENCODING"        @keyword
"DATEFORMAT"      @keyword
"TIMESTAMPFORMAT" @keyword
"HEADER"          @keyword
; `NULL` names an option here, not the literal.
(load_option "NULL" @keyword)

(load_statement table: (table_ref) @variable)
; Explicit target column list: LOAD t (a, b) 'file.csv'
(load_statement (identifier) @variable.member)
; Enum-like option value: (FORMAT csv)
(load_option value: (identifier) @constant)

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

; ─── PL/SQL (Oracle) ─────────────────────────────────────────────────────────

; Declared names
(create_procedure_statement name: (table_ref) @function)
(create_package_statement name: (table_ref) @module)
(subprogram_declaration name: (identifier) @function)
(procedure_call_statement procedure: (function_name) @function.call)
(cursor_declaration name: (identifier) @variable)
(variable_declaration name: (identifier) @variable)
(exception_declaration name: (identifier) @variable)
(type_declaration name: (identifier) @type)
(record_field name: (identifier) @variable.member)
(parameter_declaration name: (identifier) @variable.parameter)
(named_argument name: (identifier) @variable.parameter)
(pragma_declaration name: (identifier) @attribute)

; Anchored types: t.col%TYPE, t%ROWTYPE
(anchored_type) @type

; Cursor attributes: c%NOTFOUND, SQL%ROWCOUNT
(cursor_attribute attribute: _ @attribute)

; Labels: <<name>>, EXIT name, GOTO name, END LOOP name
(statement_label name: (identifier) @label)
(loop_statement label: (identifier) @label)
(exit_statement label: (identifier) @label)
(continue_statement label: (identifier) @label)
(goto_statement label: (identifier) @label)

; Block / program-unit keywords
"DECLARE"   @keyword
"PROCEDURE" @keyword.function
"FUNCTION"  @keyword.function
"PACKAGE"   @keyword
"BODY"      @keyword
"CURSOR"    @keyword
"CONSTANT"  @keyword
"PRAGMA"    @keyword
"RECORD"    @keyword
"VARRAY"    @keyword
"VARYING"   @keyword
"REF"       @keyword
"OF"        @keyword
"ROWTYPE"   @keyword
"NOCOPY"    @keyword
"OUT"       @keyword
"INOUT"     @keyword

; Control flow
"LOOP"      @keyword.repeat
"WHILE"     @keyword.repeat
"FORALL"    @keyword.repeat
"REVERSE"   @keyword.repeat
"EXIT"      @keyword.repeat
"ELSIF"     @keyword.conditional
"ELSEIF"    @keyword.conditional
"GOTO"      @keyword
"RETURN"    @keyword.return

; Exceptions
"EXCEPTION"  @keyword.exception
"EXCEPTIONS" @keyword.exception
"RAISE"      @keyword.exception

; Cursor / dynamic SQL statements
"OPEN"      @keyword
"CLOSE"     @keyword
"BULK"      @keyword
"COLLECT"   @keyword
"SAVE"      @keyword

; ─── Object types ────────────────────────────────────────────────────────────

(create_type_statement name: (table_ref) @type)
(create_type_statement supertype: (table_ref) @type)
(object_attribute name: (identifier) @variable.member)
(method_specification name: (identifier) @function)

"OBJECT"       @keyword
"UNDER"        @keyword
"FORCE"        @keyword
"FINAL"        @keyword
"INSTANTIABLE" @keyword
"OVERRIDING"   @keyword
"MEMBER"       @keyword
"STATIC"       @keyword
"MAP"          @keyword
"CONSTRUCTOR"  @keyword
"SELF"         @variable.builtin
"RESULT"       @keyword

; ─── Triggers ────────────────────────────────────────────────────────────────

(create_trigger_statement name: (table_ref) @function)
(create_trigger_statement table: (table_ref) @variable)

"TRIGGER"        @keyword
"BEFORE"         @keyword
"AFTER"          @keyword
"INSTEAD"        @keyword
"EACH"           @keyword
"STATEMENT"      @keyword
"REFERENCING"    @keyword
"OLD"            @keyword
"NEW"            @keyword
"PARENT"         @keyword
"FOLLOWS"        @keyword
"PRECEDES"       @keyword
"ENABLE"         @keyword
"DISABLE"        @keyword
"EDITIONABLE"    @keyword
"NONEDITIONABLE" @keyword

; NULL as a statement and in NOT NULL constraints
"NULL" @constant.builtin

; PL/SQL operators
":=" @operator
"=>" @operator
".." @operator
"%"  @operator

; ─── Punctuation ─────────────────────────────────────────────────────────────

";" @punctuation.delimiter
"," @punctuation.delimiter
"." @punctuation.delimiter
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
