package xchange

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"

// TODO: Macro expansion in macro body
// TODO: Non explicit macro calls?

// Configuration

FILE_NAME :: "temp.txt"

// The string that denotes the start of a macro call
LEADER := "@"
ERR_ON_REDEF :: true
ERR_ON_UNDEF_NONEXISTANT :: false
ENABLE_LOGGING :: true

// Reserved names that cannot be defined. 
RESERVED_WORDS :: []string{ 
    "def", "include", "repeat", "if", "elseif", "endif",
    "note", "noteStart", "noteEnd" 
}

// Structures
Macro :: struct {
    args: [dynamic]string,
    body: string
}

Group :: enum {
    If,
    Repeat,
}

GroupHeader :: struct {
    group: Group,
}

Reader :: struct {
    src: string,
    sb: ^strings.Builder,
    defs: map[string]Macro,
    groupStack: [dynamic]GroupHeader
}

// Utilities

error :: proc(msg:string, args:..any) {
    fmt.printf("ERROR: ")
    fmt.printf(msg, ..args)
    fmt.println()
    os.exit(-1)
}

// Grabs what would be considered a "word" 
//   from the input string and returns the rest alongside it
chopWord :: proc(s:string) -> (word: string, rest: string) {
    s2 := strings.trim_left_space(s)
    stop := strings.index_any(s2, "\n\t \r(\000@")
    if stop == -1 do return "", s2
    return s2[:stop], s2[stop:]
}

// Grabs what would be considered a "word" 
//   from the input string on the same line and 
//   returns the rest alongside it
chopWordSameLine :: proc(s:string) -> (word:string, rest:string) {
    s2 := strings.trim_left_space(s)
    eol := strings.index(s2, "\n\r")
    // If there is no newline
    if eol == -1 {
        stop := strings.index_any(s2, "\t (\000@")
        if stop == -1 do return "", s2
        return s2[:stop], s2[stop:]
    }
    stop := strings.index_any(s2[:eol], "\n\t \r(\000@")
    if stop == -1 do return "", s2
    return s2[:stop], s2[stop:]

}

// Runs a function that takes a portion of a string and returs what's left after
//  and runs it on a reader, manipulating the internal string tracker
readerExtract :: proc(r:^Reader, extractor:proc(t:string) -> (ext:$T, rest:string)) -> T {
    ext, rest := extractor(r.src)
    r.src = rest
    return ext
}

// Adds text to the beginning of a reader
readerPrepend :: proc(r:^Reader, text:string, addNL := false) {
    res, err := strings.concatenate({text, addNL ? "\n" : "", r.src[:]})
    if err != nil {
        error("Could not concatenate the new file with the existing")
    }
    r.src = res
}

main :: proc() {
    // fmt.printfln("%t", slice.any_of([]int{1,2,3}, 1))

    // when true do return
    txt, ok := os.read_entire_file_from_filename(FILE_NAME)
    if !ok {
        fmt.printfln("Could not open file")
        return
    }
    ret := parseText(string(txt))
    fmt.printf("%s", ret)
}

readerTrimLeftNoNL :: proc(r:^Reader) {
    r.src = strings.trim_left(r.src, " \t")
}

// Logs a message about the status of a reader struct
readerStatus :: proc(r:^Reader) {
    if !ENABLE_LOGGING do return
    ns1, a1 := strings.replace_all(strings.to_string(r.sb^), "\n", "$N")
    defer if a1 do delete(ns1)
    ns2, a2 := strings.replace_all(r.src, "\n", "$N")
    defer if a2 do delete(ns2)
    fmt.printf("vvvvvvvvvvvvvvvvv\n")
    fmt.printf("| defs: \n")
    for k,v in r.defs {
        fmt.printf("|   '%s %s' => '%s'\n", k, v.args, v.body)
    }
    fmt.printf("| Already Read:\n| - `%s`\n", ns1)
    fmt.printf("| To Read:\n| - `%s`\n", ns2)
    fmt.printf("^^^^^^^^^^^^^^^^^\n")
}

isWhitespace :: proc(c: u8) -> bool {
    return c == ' ' || c == '\n' || c == '\t'
}
isWhitespaceRune :: proc(c: rune) -> bool {
    return c == ' ' || c == '\n' || c == '\t'
}
// Reads any leading whitespace in the internal buffer and ignores it
skipWS :: proc(r:^Reader) {
    notWS := strings.index_proc(r.src, strings.is_separator)
    if notWS == -1 do return
    r.src = r.src[notWS:]
}
// Reads all bytes until the leader string
readUntilString :: proc(r:^Reader, s: string) {
    idx := strings.index(r.src, s)
    if idx == -1 {
        strings.write_string(r.sb, r.src)
        r.src = ""
        return
    }

    strings.write_string(r.sb, r.src[:idx])
    r.src = r.src[idx:]
}
readUntilCharset :: proc(r:^Reader, chars:string) -> string {
    idx := strings.index_any(r.src, chars)
    if idx == -1 {
        ret := r.src[:]
        r.src = ""
        return ret
    }
    ret := r.src[:idx]
    r.src = r.src[idx:]
    return ret
}

isAlNum :: proc(c:rune) -> bool {
    return  (c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            (c == '_')
}

parseText :: proc(text: string, defs: map[string]Macro = nil) -> string {
    sb, err := strings.builder_make_len(len(text))
    if err != nil do error("Could not create builder")
    r := Reader { 
        src = text[:], 
        sb = &sb, 
        defs = make(map[string]Macro),
        groupStack = make([dynamic]GroupHeader)
    }
    // Clone the defs context to allow macro expansion inside a string
    if defs != nil {
        for k,v in defs {
            r.defs[k] = Macro{
                body = v.body,
                args = make([dynamic]string)
            }
            nd := r.defs[k].args
            for a in v.args {
                append(&nd, a)
            }
        }
    }

    for r.src != "" {
        readUntilString(&r, LEADER)
        if strings.has_prefix(r.src, LEADER) {
            // Remove Leader
            r.src = r.src[len(LEADER):]
            resolveMacro(&r)
        }
        readerStatus(&r)
    }
    return strings.clone(strings.to_string(sb))
}

chopParens :: proc(s:string) -> (args:[dynamic]string, rest:string) {
    rest = strings.trim_left(s, " \t")
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
// Reads an argument list from a reader and checks for an arg count
readerArgCount :: proc(r:^Reader, cmd:string, argc:..int = 1) -> (args:[dynamic]string) {
    args = readerExtract(r, chopParens)
    // TODO: Logging for multiple argc counts
    if args == nil {
        error("Command %s was called without args or (). Expected %d arguments", cmd, argc[0])
    } 
    if !slice.any_of(argc, len(args)) {
        error("Command %s was called with the wrong number of arguments. %d were expected", cmd, argc[0])
    }
    return args
}

readUntilNL :: proc(r:^Reader) -> string {
    ret := readUntilCharset(r, "\n")
    // Remove \n
    if len(r.src) > 0 do r.src = r.src[1:]
    return ret
}

// TODO
resolveMacro :: proc(r:^Reader) {
    // Macro time!
    idx := strings.index_proc(r.src[:], isAlNum, false)
    // if idx == -1 do error("Nothing after macro initializer\n")
    if idx != 0 && idx != -1 {
        cmd := readerExtract(r, chopWord)
        // cmd := r.src[:idx]
        if ENABLE_LOGGING do fmt.printf("CMD: `%s`\n", cmd)
        // r.src = r.src[idx:]
        switch cmd {
            case "def": {
                // TODO: Rewrite this
                // name := readerExtract(r, chopWord)
                // if name == "" do error("No name given for %sdef", LEADER)
                // args := readerExtract(r, chopParens)
                // rest := readUntilNL(r)
                // r.defs[name] = {
                //     args = args,
                //     body = rest
                // }
                // if ENABLE_LOGGING do fmt.printf("  Name: %s\n  Args: %s\n  Body: %s\n",
                //     name, args, rest)
                
                eol := strings.trim_left_space(readUntilNL(r))
                if len(eol) == 0 {
                    error("Nothing after def macro")
                }
                // Check for def name
                stop := strings.index_any(eol, "\n\t \r(")
                if stop == -1 {
                    error("Nothing after def name %s", eol)
                }
                defName := eol[:stop]
                if defName in r.defs && ERR_ON_REDEF {
                    error("Redefinition of macro '%s'", defName)
                }
                eol = strings.trim_space(eol[stop:])
                if ENABLE_LOGGING do fmt.printf("  Name: %s\n", defName)

                // Check for (arg,arg)
                args, rest := chopParens(eol)
                if ENABLE_LOGGING do fmt.printf("  Args: ")
                if ENABLE_LOGGING do fmt.println(args)
                r.defs[defName] = {
                    args = args,
                    body = rest
                }
                if ENABLE_LOGGING do fmt.printfln("  Body: `%s`", rest)
            }
            case "undef": {
                skipWS(r)
                readerStatus(r)
                toUndef := readerExtract(r, chopWord)
                if strings.trim_space(toUndef) == "" {
                    error("Trying to undef nothing")
                }
                if toUndef in r.defs {
                    delete_key(&r.defs, toUndef)
                } else {
                    if ERR_ON_UNDEF_NONEXISTANT {
                        error("Trying to undef '%s' but it is not defined", toUndef)
                    }
                }
                if ENABLE_LOGGING do fmt.printf("Undef '%s'\n", toUndef)
            }
            case "note": {
                // Ignore everything else on the line
                readUntilNL(r)
            }
            case "noteStart": {
                leadStop, err := strings.concatenate({LEADER, "noteStop"})
                if err != nil do error("Could not concat for noteStop")
                defer delete(leadStop)
                lsIdx := strings.index(r.src, leadStop)
                if lsIdx == -1 do error("No %snoteStop for a started %snoteStart", LEADER, LEADER)
                r.src = r.src[lsIdx + len(leadStop):]
                // Eat trailing newlines
                if len(r.src) > 0 && r.src[0] == '\n' do r.src = r.src[1:]
            }
            case "noteStop": {
                error("Reached %snoteEnd without %snoteStart", LEADER, LEADER)
            }
            case "repeat": {
                repeatStop, err := strings.concatenate({LEADER, "repeatEnd"})
                if err != nil do error("Could not concat for repeatEnd")
                defer delete(repeatStop)

                //unimplemented("@repeat(arg, <range>)")
                error("Unimplimented: ")
            }
            case "calc", "eval": {
                args := readerArgCount(r, "calc", 1)
                defer delete(args)
                // TODO: Could use the lua library?

                error("TODO calc on %s", args[0])
                // Need to resolve arguments first
            }
            case "include": {
                args := readerExtract(r, chopParens)
                defer delete(args)
                if(len(args) != 1) {
                    error("Invalid argument count for %sinclude. Expected 1 arg", LEADER)
                }
                newFile, readOK := os.read_entire_file_from_filename(args[0])
                if !readOK {
                    error("Could not include file '%s'", args[0])
                }  

                readerPrepend(r, string(newFile), true)
                // unimplemented("@include")
            }
            case "if": {
                unimplemented("@if")
            }
            case "elseif": {
                unimplemented("@elseif")
            }
            case "endif": {
                unimplemented("@endif")
            }
            case: {
                if cmd not_in r.defs {
                    error("Call to undefined macro '%s%s'", LEADER, cmd)
                }
                args := readerExtract(r, chopParens)
                macro := r.defs[cmd]
                if len(macro.args) != len(args) {
                    error("Call to %s has invalid arg count. Expected %d, but got %d", cmd, len(macro.args), len(args))
                }
                // TODO: Does not detect macro at end of string

                // If no args and the next char is the LEADER, skip it.
                //   This allows in place macro calls
                if args == nil {
                    if strings.index(r.src, LEADER) == 0 {
                        r.src = r.src[1:]
                    }
                    strings.write_string(r.sb, r.defs[cmd].body)
                } else {
                    newText, hasAlloc := macro.body[:], false
                    defer if hasAlloc do delete(newText)
                    // TODO: Better find and replace method
                    for arg,i in args {
                        if ENABLE_LOGGING do fmt.printf("  Replacing '%s' with '%s'\n",macro.args[i], arg)
                        newText, hasAlloc = strings.replace_all(newText, macro.args[i], arg)
                    }
                    // TODO: Decide which approach is better
                    readerPrepend(r, newText)
                    // strings.write_string(r.sb, parseText(newText, r.defs))
                    delete(args)
                }

            }
        }
    } else {
        // Not a macro? Keep the leader
        when ENABLE_LOGGING do fmt.printfln("Not a macro")
        if len(r.src) > 0 do strings.write_string(r.sb, LEADER)
    }
}

