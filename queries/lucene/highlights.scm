(comment) @comment

(index_name) @namespace
"|" @punctuation.delimiter
"," @punctuation.delimiter

(field_name) @property
(term) @string
(phrase) @string
(escape_sequence) @string.escape
(regex) @string.regexp
(range_value) @string

; A term that is a number reads better as one, `total:>50`.
((term) @number
  (#match? @number "^[0-9]+(\\.[0-9]+)?$"))

; A wildcard is an operator on the term, not part of its text.
(wildcard) @operator

; `_exists_:field` names a field, not a value.
((clause
  field: (field_name) @keyword.operator
  value: (term) @property)
  (#eq? @keyword.operator "_exists_"))

(binary_expr op: _ @keyword.operator)
(unary_expr op: _ @keyword.operator)
"TO" @keyword.operator

(comparison op: _ @operator)
(fuzzy) @operator
"^" @operator
(boost (number) @number)

":" @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket
