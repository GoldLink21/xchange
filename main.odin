package xchange

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:slice"
import "core:path/filepath"

// TODO: Macro expansion in macro body
// TODO: Non explicit macro calls?

///////////////////
// Configuration //
///////////////////

// Throw an error when redefining a variable
ERR_ON_REDEF                :: true
// Throw an error when undef-ing a variable that doesn't exist
ERR_ON_UNDEF_NONEXISTANT    :: false

// Simple expanded logging
@private
ENABLE_LOGGING              :: false

///////////////
// Utilities //
///////////////

@(private)
error :: proc(msg:string, args:..any, loc:= #caller_location) {
    fmt.printf("ERROR ")
    fmt.print(loc)
    fmt.printf(": ")
    fmt.printf(msg, ..args)
    fmt.println()
    os.exit(-1)
}

@(private)
errorPos :: proc(pos: TokenPos, msg:string, args:..any, loc:= #caller_location) {
    fmt.printf("ERROR ")
    printTokLoc(pos)
    fmt.printf(": ")
    fmt.printf(msg, ..args)
    fmt.println()
    os.exit(-1)
}

@(private)
isAlNum :: proc(c:rune) -> bool {
    return  (c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            (c == '_')
}

// Grabs what would be considered a "word" 
//   from the input string and returns the rest alongside it
// @unused
@(private)
chopWord :: proc(s:string) -> (word: string, rest: string) {
    s2 := strings.trim_left_space(s)
    stop := strings.index_any(s2, "\n\t \r(\000@")
    if stop == -1 do return "", s2
    return s2[:stop], s2[stop:]
}

// Grabs what would be considered a "word" 
//   from the input string on the same line and 
//   returns the rest alongside it
// @unused
@(private)
chopWordSameLine :: proc(s:string, $SAME_LINE: bool) -> (word:string, rest:string) {
    s2 := strings.trim_left_space(s)
    eol := strings.index(s2, "\n")
    // If there is no newline
    if eol == -1 {
        when SAME_LINE {
            stop := strings.index_any(s2, "\t (\000@")
        } else {
            stop := strings.index_any(s2, "\t (\000@\n")
        }
        if stop == -1 do return "", s2
        return s2[:stop], s2[stop:]
    }
    stop := strings.index_any(s2[:eol], "\n\t \r(\000@")
    if stop == -1 do return "", s2
    return s2[:stop], s2[stop:]

}

// Parse text and resolve it as it is. filePath arg is used for any @include macros
parseText :: proc(text: string, filePath:=".", args:..string) -> (ret:string, ok: bool) {
    dir := filepath.dir(filePath)
    defer delete(dir)
    os.change_directory(dir)
    tokens := lexText(string(text), filePath)
    out, ctx := resolveTokens(tokens, args)
    defer context_destroy(&ctx)
    return out, true
}

parseFile :: proc(fileName: string, args:..string) -> (ret: string = "", ok: bool) {
    txt, fileOk := os.read_entire_file_from_filename(fileName)
    if !fileOk {
        return "", false
    }
    defer delete(txt)
    // Move into the directory of the file for referencing files in it
    dir := filepath.dir(fileName)
    defer delete(dir)
    os.change_directory(dir)
    tokens := lexText(string(txt), fileName)
    out, ctx := resolveTokens(tokens, args)
    defer context_destroy(&ctx)
    return out, true
}
// Block out main when not exe
when ODIN_BUILD_MODE == .Executable {
main :: proc() {
    if len(os.args) == 1 do error("Pass in the file to parse")
    fileName := os.args[1]
    
    if fileName == "help" || fileName == "?" {
        printHelp()
        return
    }

    txt, fileOk := os.read_entire_file_from_filename(fileName)
    if !fileOk {
        fmt.printfln("Could not open file")
        return
    }
    defer delete(txt)
    // Move into the directory of the file for referencing files in it
    dir := filepath.dir(os.args[1])
    defer delete(dir)
    os.change_directory(dir)

    tokens := lexText(string(txt), fileName)
    when ENABLE_LOGGING {
        fmt.println("\nvvvvvvvvTokensvvvvvvvvvvv")
        printTokens(tokens)
        fmt.println("\n--------Resolve----------")
    }
    out, ctx := resolveTokens(tokens, os.args[2:])
    defer context_destroy(&ctx)
    when ENABLE_LOGGING {
        fmt.println("\n--------Output-----------")
    }
    // fmt.print("<")
    fmt.print(out)
    // fmt.print(">")
    when ENABLE_LOGGING {
        fmt.println("\n$$$$$$$$$End$$$$$$$$$$$$$")
    }
}
}

@(private)
isWhitespace :: proc(c: u8) -> bool {
    return c == ' ' || c == '\n' || c == '\t'
}
@(private)
isWhitespaceNoNL :: proc(c:u8) -> bool {
    return c == ' ' || c == '\t'
}
@(private)
isWhitespaceRune :: proc(c: rune) -> bool {
    return c == ' ' || c == '\n' || c == '\t'
}

@(private)
chopParens :: proc(s:string) -> (args:[dynamic]string, rest:string) {
    rest = strings.trim_left(s, " \t")
    // rest = strings.trim_left_space(s)
    if len(rest) > 0 && rest[0] == '(' {
        args = make([dynamic]string)
        // Remove (
        rest = rest[1:]
        loop: for i := 0; i < len(rest); i+=1 {
            if rest[i] == ',' {
                // Slice w/o ,
                // TODO: Trim args
                append(&args, strings.trim_space(rest[:i]))
                rest = rest[i+1:]
                i = 0
            } else if rest[i] == ')' {
                append(&args, strings.trim_space(rest[:i]))
                rest = rest[i:]
                break loop
            }
        }
        if rest[0] != ')' {
            error("Macro started ( but has no closing )")
        }
        // TODO: Check for duplicate args
        rest = strings.trim_left_space(rest[1:])
        // Explicit check for ()
        if len(args) == 1 && args[0] == "" do pop(&args)
        return args, rest
    }
    return nil, s
}

printHelp :: proc() {
    fmt.printfln("There is no help for you")
}