package dev.monogon.cue.lang.lexer;

import com.intellij.lexer.FlexLexer;
import com.intellij.psi.tree.IElementType;
import it.unimi.dsi.fastutil.ints.IntArrayList;

import static com.intellij.psi.TokenType.BAD_CHARACTER;
import static com.intellij.psi.TokenType.WHITE_SPACE;
import static dev.monogon.cue.lang.CueTypes.*;
import static dev.monogon.cue.lang.CueTokenTypes.*;

%%

%{
  public _CueLexer() {
    this((java.io.Reader)null);
  }

  private final IntArrayList stateStack = new IntArrayList(100);

  // the number of # characters, which define the current escape character, e.g. 1 for \#<escaped>
  private int escapePrefixLength = 0;
  // the escape prefix lengths of previous states on the stack
  // nesting is possible because of interpolations
  private final IntArrayList escapePrefixLengthStack = new IntArrayList(100);

  private void pushState(int state) {
      int currentState = yystate();
      if (currentState == YYINITIAL && !stateStack.isEmpty()) {
          throw new IllegalStateException("Can't push initial state into the not empty stack");
      }
      stateStack.push(currentState);
      yybegin(state);

      escapePrefixLengthStack.push(escapePrefixLength);
      escapePrefixLength = 0;
  }

  private void popState() {
    assert !stateStack.isEmpty() : "States stack is empty";
    yybegin(stateStack.popInt());

    assert !escapePrefixLengthStack.isEmpty() : "Escape prefix length stack is empty";
    escapePrefixLength = escapePrefixLengthStack.popInt();
  }

  /** Called when an instance is reset, e.g. on incremental lexer restart */
  protected void onReset() {
    stateStack.clear();

    escapePrefixLength = 0;
    escapePrefixLengthStack.clear();
  }

  private void updateEscapePrefix() {
      int length = yylength();
      while (escapePrefixLength < length && yycharat(escapePrefixLength) == '#') {
          escapePrefixLength++;
      }
  }

  private boolean isEscapePrefix() {
      return isEscapePrefix(0);
  }

  private boolean isEscapePrefix(int startOffset) {
      int count = 0;
      int length = yylength();
      for (int i = startOffset; i < length; i++) {
          if (yycharat(i) != '#') {
              break;
          }
          count++;
      }
      return count == escapePrefixLength;
  }

  private boolean isEscapeSuffix() {
      int count = 0;
      int length = yylength();
      for (int i = length - 1; i >= 0; i--) {
          if (yycharat(i) != '#') {
              break;
          }
          count++;
      }
      return count == escapePrefixLength;
  }
%}

%class _CueLexer
%implements FlexLexer
%unicode
%public

%function advance
%type IElementType

// White space, formed from spaces (U+0020), horizontal tabs (U+0009), carriage returns (U+000D), and newlines (U+000A)
// IntelliJ: tokenizing newlines, which are whitespace, as separate tokens to simplify our CueCommaInsertingLexer
WHITE_SPACE=[ \t\r]
WHITE_SPACE_NEWLINE=[\n]
WHITE_SPACE_ANY=[ \t\r\n]

// https://cuelang.org/docs/references/spec/#characters
newline        = \n /* the Unicode code point U+000A */
unicode_char   = [^\n] /* an arbitrary Unicode code point except newline */
unicode_letter = [\p{Lu}\p{Ll}\p{Lt}\p{Lm}\p{Lo}] /* a Unicode code point classified as "Letter" */
unicode_digit  = [\p{Nd}] /* a Unicode code point classified as "Number, decimal digit" */

// https://cuelang.org/docs/references/spec/#letters-and-digits
letter        = {unicode_letter} | [_$] // IntelliJ: added $, which is defined, but not listed in the spec
decimal_digit = [0-9]
octal_digit   = [0-7]
hex_digit     = [0-9A-Fa-f]
binary_digit  = [0-1]
letter_digit  = {letter} | {unicode_digit} // extension: letter or digit

// https://cuelang.org/docs/references/spec/#commas
comma       = [,]

// https://github.com/cuelang/cue/blob/master/doc/ref/spec.md#keywords
// identifiers starting with __ are reserved keywords
keyword_identifier = "__" {letter_digit}*

// https://cuelang.org/docs/references/spec/#identifiers
identifier  = ("#" | "_#")? {letter} {letter_digit}*

// https://cuelang.org/docs/references/spec/#letters-and-digits
decimal_lit = "0" | [1-9] ("_"? {decimal_digit})*
decimals    = {decimal_digit} ("_"? {decimal_digit})*
si_lit      = {decimals} ("." {decimals})? {multiplier}
              | "." {decimals} {multiplier}
binary_lit  = "0b" {binary_digit} ("_"? {binary_digit})*
hex_lit     = "0" [xX] {hex_digit} ("_"? {hex_digit})*
octal_lit   = "0o" {octal_digit} ("_"? {octal_digit})*
multiplier  = [KMGTP] "i"?

// https://cuelang.org/docs/references/spec/#decimal-floating-point-literals
float_lit = {decimals} "." {decimals}? {exponent}?
            | {decimals} {exponent}
            | "." {decimals} {exponent}?
exponent  = [eE] [+-]? {decimals}

// https://cuelang.org/docs/references/spec/#string-and-byte-sequence-literals
escaped_char     = "\\" "#"* [abfnrtv/\\'\"]
byte_value       = {octal_byte_value} | {hex_byte_value}
octal_byte_value = "\\" [#]*     {octal_digit} {3}
hex_byte_value   = "\\" [#]* "x" {hex_digit}   {2}
little_u_value   = "\\" [#]* "u" {hex_digit}   {4}
big_u_value      = "\\" [#]* "U" {hex_digit}   {8}
// IntelliJ: we're lexing escaped characters as a separate token, mostly for highlighting
unicode_value    = {unicode_char} /*| {little_u_value} | {big_u_value} | {escaped_char}*/

%state STRING_LITERAL
%state STRING_MULTILINE
%state BYTE_LITERAL
%state BYTES_MULTILINE
%state INTERPOLATION
%state PARENTHESIS

%%
<STRING_LITERAL> {
    "\"" [#]*       { if (isEscapeSuffix()) { popState(); return DOUBLE_QUOTE_END; } else { return UNICODE_VALUE; } }
}
<BYTE_LITERAL> {
    "'" [#]*        { if (isEscapeSuffix()) { popState(); return SINGLE_QUOTE_END; } else { return UNICODE_VALUE; } }
    {byte_value}    { return BYTE_VALUE; }
}
<STRING_MULTILINE> {
    // IntelliJ: matching \n as newline token, because the closing triple-quote must come after it
    {newline}       { return NEWLINE; }
    "\"\"\"" [#]*   { if (isEscapeSuffix()) { popState(); return MULTILINE_STRING_END; } else { return UNICODE_VALUE; } }
}
<BYTES_MULTILINE> {
    // IntelliJ: matching \n as newline token, because the closing triple-quote must come after it
    {newline}       { return NEWLINE; }
    "'''" [#]*      { if (isEscapeSuffix()) { popState(); return MULTILINE_BYTES_END; } else { return UNICODE_VALUE; } }
}
<STRING_LITERAL, BYTE_LITERAL, STRING_MULTILINE, BYTES_MULTILINE> {
    "\\" [#]* "("         { if (isEscapePrefix(1)) { pushState(INTERPOLATION); return INTERPOLATION_START; } else { return UNICODE_VALUE; } }
    // fixme decide if we want to lex whitespace in strings as unicode_value or whitespace,
    //   might be needed for in-string-content search and tokenizing
    {little_u_value}
    | {big_u_value}
    | {escaped_char}      { if (isEscapePrefix(1)) { return ESCAPED_CHAR; } else { return UNICODE_VALUE; } }
    {unicode_value}       { return UNICODE_VALUE; }
}

<INTERPOLATION> {
    ")"                   { popState(); return INTERPOLATION_END; }
}
<PARENTHESIS> {
    ")"                   { popState(); return RIGHT_PAREN; }
}

<YYINITIAL, INTERPOLATION, PARENTHESIS> {
    "package" | "import"
    | "for" | "in" | "if" | "let"
                     { return KEYWORD; } // for now, one token for all, https://cuelang.org/docs/references/spec/#keywords
    "null"           { return NULL_LIT; } // https://cuelang.org/docs/references/spec/#null
    "true" | "false" { return BOOL_LIT; } // fixme currently undefined in spec
    "_|_"            { return BOTTOM_LIT; }

    // operator tokens
    "{"     { return LEFT_CURLY; }
    "}"     { return RIGHT_CURLY; }
    ":"     { return COLON; }
    "..."   { return ELLIPSIS_TOKEN; }
    ","     { return COMMA; }
    "="     { return EQ; }
    "?"     { return QMARK; }
    "@"     { return AT; }
    "["     { return LEFT_BRACKET; }
    "]"     { return RIGHT_BRACKET; }
    "("     { pushState(PARENTHESIS); return LEFT_PAREN; }
    ")"     { return RIGHT_PAREN; }

    "!=" | "<" | "<=" | ">" | ">=" | "=~" | "!~"
            { return REL_OP; }
    "+" | "-"
            { return ADD_OP; }
    "*" | "/"
            { return MUL_OP; }
    "|"     { return OP_DISJUNCTION; }
    "&"     { return OP_UNIFICATION; }
    "||"    { return OP_OR; }
    "&&"    { return OP_AND; }
    "=="    { return OP_EQ; }
    // end of operators

    "?"     { return QMARK; }
    "!"     { return EXCL; }
    "."     { return DOT; }

    // identifiers, alternatively, we could match predeclared identifiers in an annotator for highlighting, but that's slower
    // functions
    "len"
   | "close"
   | "and"
   | "or"
   | "div"
   | "mod"
   | "quo"
   | "rem"  { return IDENTIFIER_PREDECLARED; }

    // types
    // null is also a null_lit
    //"null"
      "bool"
    | "int"
    | "float"
    | "string"
    | "bytes"       { return IDENTIFIER_PREDECLARED; }
    // derived
    "number"
    |"uint"
    |"uint8"
    |"int8"
    |"uint16"
    |"int16"
    |"rune"
    |"uint32"
    |"int32"
    |"uint64"
    |"int64"
    |"uint128"
    |"int128"
    |"float32"
    |"float64"      { return IDENTIFIER_PREDECLARED; }
    // others, not predefined
    {keyword_identifier}    { return KEYWORD; } // fixme: we could use a KEYWORD_RESERVED token if necessary for highlighting
    {identifier}            { return IDENTIFIER; }
    // end of identifiers

    {float_lit}     { return FLOAT_LIT; }
    {decimal_lit}
     | {si_lit}
     | {octal_lit}
     | {binary_lit}
     | {hex_lit}    { return INT_LIT; }

    [#]* "\""                   { pushState(STRING_LITERAL); updateEscapePrefix(); return DOUBLE_QUOTE; }
    [#]* "\"\"\""               { pushState(STRING_MULTILINE); updateEscapePrefix(); return MULTILINE_STRING_START; }
    [#]* "'"                    { pushState(BYTE_LITERAL); updateEscapePrefix(); return SINGLE_QUOTE; }
    [#]* "'''"                  { pushState(BYTES_MULTILINE); updateEscapePrefix(); return MULTILINE_BYTES_START; }

    "//" {unicode_char}* {newline}?   { return COMMENT; }
}

{WHITE_SPACE_NEWLINE}   { return WHITE_SPACE_NEWLINE; }
{WHITE_SPACE}           { return WHITE_SPACE; }
[^]                     { return BAD_CHARACTER; }
