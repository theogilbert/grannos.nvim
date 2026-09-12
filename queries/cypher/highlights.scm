; Cypher highlights for nvim-treesitter
; https://github.com/nvim-treesitter/nvim-treesitter/blob/master/CONTRIBUTING.md

; ── Clause keywords ──────────────────────────────────────────────────────────

[
  (kw_explain)
  (kw_profile)
  (kw_index)
  (kw_match)
  (kw_optional)
  (kw_create)
  (kw_merge)
  (kw_delete)
  (kw_detach)
  (kw_set)
  (kw_remove)
  (kw_with)
  (kw_return)
  (kw_unwind)
  (kw_call)
  (kw_yield)
  (kw_foreach)
  (kw_union)
  (kw_all)
] @keyword

; ── Sub-clause keywords ───────────────────────────────────────────────────────

[
  (kw_where)
  (kw_order)
  (kw_by)
  (kw_skip)
  (kw_limit)
  (kw_on)
  (kw_as)
  (kw_distinct)
  (kw_in)
  (kw_for)
  (kw_if)
] @keyword

; ── Sorting direction ─────────────────────────────────────────────────────────

[
  (kw_asc)
  (kw_ascending)
  (kw_desc)
  (kw_descending)
] @keyword.modifier

; ── CASE expression ───────────────────────────────────────────────────────────

[
  (kw_case)
  (kw_when)
  (kw_then)
  (kw_else)
  (kw_end)
] @keyword

; ── Logical operators ─────────────────────────────────────────────────────────

[
  (kw_and)
  (kw_or)
  (kw_xor)
  (kw_not)
] @keyword.operator

; ── String / type predicates ─────────────────────────────────────────────────

[
  (kw_starts)
  (kw_ends)
  (kw_with)
  (kw_contains)
  (kw_is)
  (kw_exists)
] @keyword.operator

; ── Literals ─────────────────────────────────────────────────────────────────

(string_literal) @string

(integer_literal) @number

(float_literal) @number.float

(boolean_literal) @boolean

(null_literal) @constant.builtin

; ── Parameters ───────────────────────────────────────────────────────────────

(parameter) @variable.parameter

; ── Variables ────────────────────────────────────────────────────────────────

(variable) @variable

; ── Labels and relationship types ────────────────────────────────────────────

(label_name) @type

(relationship_type) @type

; Label expression operators  :A&B  :A|B  :!A  (the wildcard "%" is
; already an operator above)
[
  "&"
  "!"
] @operator

(label_disjunction "|" @operator)

; ── Map keys  { key: value } ─────────────────────────────────────────────────

(map_key) @property

; ── Property access  n.prop ──────────────────────────────────────────────────

; In general expressions: seq(expression, ".", identifier)
(expression "." (identifier) @property)

; In SET/REMOVE property_expression: variable is wrapped, bare identifiers are props
(property_expression (identifier) @property)

; ── Functions ────────────────────────────────────────────────────────────────

(function_invocation
  (function_name) @function.call)

(call_clause (procedure_name) @function.call)

; ── Operators ────────────────────────────────────────────────────────────────

[
  "="
  "<>"
  "!="
  "<"
  ">"
  "<="
  ">="
  "=~"
  "+="
  "+"
  "-"
  "*"
  "/"
  "%"
  "^"
] @operator

; ── Punctuation ──────────────────────────────────────────────────────────────

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  ";"
  ":"
  "."
  "|"
  ".."
] @punctuation.delimiter

; ── Comments ─────────────────────────────────────────────────────────────────

(comment) @comment @spell
