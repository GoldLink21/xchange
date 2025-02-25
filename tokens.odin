package xchange
import "core:fmt"
import "core:strings"

///////////////
// Constants //
///////////////

// The string that denotes the start of a macro call
LEADER          :: #config(leader, "@")
@(private)
LEADER_LEADER   :: LEADER + LEADER

// Macro Formats
FMT_JOIN        :: "~"
FMT_LOWER       :: "_"
FMT_NEWLINE     :: "N"

// Allows escaping the leader character
FMT_ESCAPE      :: "\\" + LEADER

#assert(len(LEADER) == 1, "Leader must be one character")

////////////////
// Structures //
////////////////

TokenType :: enum {
    Whitespace,
    Newline,
    Text,
    Macro,
}

TokenPos :: struct {
    // Spot in global frame
    i: int,
    // Line number
    line: int,
    // Column number
    col: int,
    // File name
    file: string,
}
Token :: struct {
    type: TokenType,
    src:  string,
    pos:  TokenPos,
}

////////////////
// Tokenizing //
////////////////


// Convert text into tokens
@private
lexText :: proc(inputText:string, fileName: string) -> [dynamic]Token {
    tokens := make([dynamic]Token)
    text   := inputText[:]
    // Characters that split elements up
    SPLIT :: "(),\r"
    index, line, column := 0, 1, 1

    for len(text) > 0 {
        switch {
            // Ignore windows specific annoyances
            case text[0] == '\r': { text = text[1:] }
            // Read whitespace
            case isWhitespaceNoNL(text[0]): {
                wsEnd := strings.index_proc(text, proc(r:rune) -> bool {
                    return r != ' ' && r != '\t'
                })
                if wsEnd == -1 do wsEnd = len(text)
                append(&tokens, Token{
                    type = .Whitespace,
                    src = text[0:wsEnd],
                    pos = { index, line, column, fileName }
                })
                text = text[wsEnd:]
                // Token Positioning
                column += wsEnd
                index += wsEnd
            }
            // Read NL
            case text[0] == '\n': {
                append(&tokens, Token{
                    type = .Newline,
                    src = text[:1],
                    pos = { index, line, column, fileName }
                })
                text = text[1:]
                // Token Positioning
                line += 1
                column = 1
                index += 1
            }
            // REMOVED

            // Read macro character
            case strings.starts_with(text, LEADER): {
                wsStart := strings.index_proc(text, isWhitespaceRune, true)
                if wsStart == -1 do wsStart = len(text)
                parenStart := strings.index_any(text, SPLIT)
                if parenStart == -1 do parenStart = wsStart
                sliceStart := min(parenStart, wsStart)
                append(&tokens, Token{
                    type = .Macro,
                    src = text[len(LEADER):sliceStart],
                    pos = { index, line, column, fileName }
                })
                text = text[sliceStart:]
                // Token Positioning
                column += sliceStart
                index += sliceStart
            }
            // PLACED
            // Read individual split tokens
            case strings.index_byte(SPLIT + LEADER, text[0]) != -1: {
                append(&tokens, Token{
                    type = .Text,
                    src = text[:1],
                    pos = { index, line, column, fileName }
                })
                text = text[1:]
                // Token Positioning
                column += 1
                index += 1
            }

            case: {
                // Trim of escaped @'s
                if strings.starts_with(text, FMT_ESCAPE) {
                    text = text[1:]
                }
                wsStart := strings.index_proc(text, isWhitespaceRune, true)
                if wsStart == -1 do wsStart = len(text)
                breakChars := strings.index_any(text, SPLIT)
                if breakChars == -1 do breakChars = wsStart
                breakIdx := min(wsStart, breakChars)

                append(&tokens, Token{
                    type = .Text,
                    src = text[:breakIdx],
                    pos = { index, line, column, fileName }
                })
                text = text[breakIdx:]
                // Token Positioning
                column += breakIdx
                index += breakIdx
            }
        }
    }
    return tokens
}

@private
printTokLoc :: proc(loc: TokenPos) {
    fmt.printf("%s(%d:%d)", loc.file, loc.line,loc.col)
}

@private
printTokens :: proc(tokens: [dynamic]Token) {
    for t in tokens {
        switch t.type {
            case .Whitespace: fmt.printf("<_>")
            case .Newline:    fmt.printf("</>\n")
            case .Macro:      fmt.printf("<(%s) %s(%d:%d)>", t.src, t.pos.file, t.pos.line, t.pos.col)
            case .Text:       fmt.printf("<'%s'>", t.src)
        }
    }
}
