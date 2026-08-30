; Подсветка Konda. Порядок важен: в Zed при совпадении нескольких паттернов на
; одном узле побеждает ПОСЛЕДНИЙ — поэтому общий (identifier) @variable идёт
; первым, а специфичные паттерны (типы, функции, поля) ниже его перекрывают.
; Ссылаться можно только на узлы/токены, реально присутствующие в грамматике
; (tools/konda-grammar) — иначе весь запрос не компилируется и язык не грузится.

; ---- Обобщённый ловец (перекрывается специфичными ниже) ----
(identifier) @variable

; ---- Литералы и комментарии ----
(comment) @comment
(preproc_directive) @preproc
(string_literal) @string
(number_literal) @number
(boolean_literal) @boolean
(null_literal) @constant.builtin

; ---- Типы в позициях типа ----
(primitive_type) @type.builtin
["возможно" "срез" "поток"] @type.builtin

(function_definition return_type: (identifier) @type)
(funptr_typedef return_type: (identifier) @type)
(parameter type: (identifier) @type)
(field_declaration type: (identifier) @type)
(variant_field type: (identifier) @type)
(var_declaration type: (identifier) @type)
(global_const type: (identifier) @type)
(cast_expression type: (identifier) @type)
(generic_type (identifier) @type)

(function_definition return_type: (scoped_identifier) @type)
(parameter type: (scoped_identifier) @type)
(var_declaration type: (scoped_identifier) @type)
(field_declaration type: (scoped_identifier) @type)

; ---- Имена в объявлениях ----
(struct_definition name: (identifier) @type)
(union_definition name: (identifier) @type)
(enum_definition name: (identifier) @type)
(extern_type name: (identifier) @type)
(funptr_typedef name: (identifier) @type)
(namespace_definition name: (identifier) @namespace)
(function_definition name: (identifier) @function)
(parameter name: (identifier) @variable.parameter)
(field_declaration name: (identifier) @property)
(enum_variant name: (identifier) @constructor)
(case_pattern name: (identifier) @constructor)
(global_const name: (identifier) @constant)

; ---- Обращения ----
(call_expression function: (identifier) @function.call)
(field_expression field: (identifier) @property)

; ---- Встроенные функции (перекрывают @function.call выше) ----
((identifier) @function.builtin
 (#match? @function.builtin "^(выделить|клон|запустить|присоединить|длина|точка_входа)$"))

; ---- Ключевые слова ----
[
  "пространство" "использовать" "структура" "союз" "перечисление"
  "внешний" "тип" "типфункции" "внешняя" "конст" "оператор"
  "если" "иначе" "пока" "для" "выбор" "вернуть"
  "небезопасно" "параллельно" "редукция" "как"
  "изменяемый" "вывод" "чтение" "неподписанный"
  "и" "или" "не"
] @keyword

(break_statement) @keyword
(continue_statement) @keyword

; ---- Операторы ----
[
  "=" "+=" "-=" "*=" "/=" "%="
  "==" "!=" "<" ">" "<=" ">="
  "+" "-" "*" "/" "%"
  "&&" "||" "!" "&" "|" "^" "<<" ">>" "~"
] @operator

; ---- Пунктуация ----
["(" ")" "{" "}" "[" "]"] @punctuation.bracket
[";" "," "::" "."] @punctuation.delimiter
