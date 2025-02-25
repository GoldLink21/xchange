package xchange

import "core:strings"
import "core:slice"
import "core:fmt"
import "core:strconv"
import "core:os"

@(private)
Macro :: struct {
    args: [dynamic]string,
    body: string
}

// Handles a current push to state
StateElement :: struct {
    start: string,
    args: map[string]string,
    body: string,
}

Frame :: struct {
    macros: map[string]Macro,
    startIndex: int,
    // nil = drop on end
    cause: FrameCause
}

FrameEach :: struct {
    elements: [dynamic]string,
    index:    int
}
// What to do when reaching @end of a repeat block
FrameRepeat :: struct { cur, to: int, isInc: bool }
// Tells what caused the frame and gives details when reaching an @end
FrameCause :: union { FrameEach, FrameRepeat }

// Allows simplifying the parsing step
TokenContext :: struct {
    tokens:     [dynamic]Token,
    i:          int,
    stackFrame: [dynamic]Frame,
    out:        strings.Builder,
    callerArgs : []string,
    isErrored: bool
}

// Names that can't be defined
RESERVED_NAMES :: []string{
    "def", "end", "note", "notes", "each", "repeat", 
    LEADER, FMT_JOIN, FMT_LOWER, FMT_NEWLINE, 
    "0", "i"
}

@private
tokCurPos :: proc(tc: ^TokenContext) -> TokenPos {
    return tokIsEmpty(tc) ? {} : tc.tokens[tc.i].pos
}

// Creates a new stack frame for resolving local macros
@private
tokNewFrame :: proc(tc: ^TokenContext, cause: FrameCause) -> ^Frame {
    append(&tc.stackFrame, Frame {
        macros = make(map[string]Macro),
        startIndex = tc.i,
        cause = cause
    })
    return &tc.stackFrame[len(tc.stackFrame) - 1]
}

// Creates a new frame with simple input value for them
@private
tokBasicFrame :: proc(tc: ^TokenContext, source: string, cause:FrameCause) {
    tokNewFrame(tc, cause)
    updateFrameTarget(tc, len(tc.stackFrame) - 1, source)
}

@private
updateFrameTarget :: proc(tc: ^TokenContext, frameIndex: int, source: string) {
    frame := &tc.stackFrame[frameIndex]
    // Resolve @0
    newIndex := fmt.tprintf("%d", frameIndex - 1)
    if newIndex in frame.macros {
        _, v := delete_key(&frame.macros, newIndex)
        delete(v.body)
        destroy_args(v.args)
    }
    frame.macros[newIndex] = Macro {
        body = strings.clone(source)
    }
}

// Removes the last frame that was pushed onto the stack
@private
tokDropFrame :: proc(tc: ^TokenContext) {
    frame := &tc.stackFrame[len(tc.stackFrame) - 1]
    for _, v in frame.macros {
        destroy_args(v.args)
        delete(v.body)
    }
    delete(frame.macros)
    switch cause in frame.cause {
        case FrameEach: {
            destroy_args(cause.elements)
        }
        case FrameRepeat: {}
    }
    pop(&tc.stackFrame)
}

// Gets a macro by name from a token context by navigating the stack backwards
@private
tokGetMacro :: proc(tc: ^TokenContext, name:string) -> (macro:Macro, ok:bool) {
    // Check from the end to allow shadowing
    for i := len(tc.stackFrame) - 1; i >= 0; i -= 1 {
        if name in tc.stackFrame[i].macros {
            return tc.stackFrame[i].macros[name]
        }
    }
    return {}, false
}

// Removes a macro if it is defined. Returns if it was removed
@private
tokRemoveMacro :: proc(tc:^TokenContext, name:string) -> (didRemove:bool) {
    // Check from the end to allow shadowing
    for i := len(tc.stackFrame) - 1; i >= 0; i -= 1 {
        if name in tc.stackFrame[i].macros {
            delete_key(&tc.stackFrame[i].macros, name)
            return true
        }
    }
    return false
}

// Skip whitespace at current location
@private
tokSkipWS :: proc(tc: ^TokenContext) {
    for tokCurIs(tc, .Whitespace) do tc.i += 1
}

// Check if current token is one of many types
@private
tokCurIs :: proc(tc: ^TokenContext, types: ..TokenType) -> bool {
    return tc.i < len(tc.tokens) && slice.any_of(types, tc.tokens[tc.i].type)
}

@private
tokNextIs :: proc(tc: ^TokenContext, types: ..TokenType) -> bool {
    return tc.i + 1 < len(tc.tokens) && slice.any_of(types, tc.tokens[tc.i + 1].type)
}

// If the current token is a newline or 
//   the current is WS and the next is a newline, skip them
@private
tokSkipIfWSNL :: proc(tc: ^TokenContext) {
    if tokCurIs(tc, .Newline) {
        tc.i += 1
    } else if tokCurIs(tc, .Whitespace) && tokNextIs(tc, .Newline) {
        tc.i += 2
    }
}

// Check if current token is text and has a certain body
@private
tokCurText :: proc(tc: ^TokenContext, text: string) -> bool {
    return tokCurIs(tc, .Text) && tc.tokens[tc.i].src == text
}

// Check if next token is text and has a certain body
@private
tokNextText :: proc(tc:^TokenContext, text:string) -> bool {
    return tokNextIs(tc, .Text) && tc.tokens[tc.i + 1].src == text
}

// Check if there are still tokens to read
@private
tokIsEmpty :: proc(tc: ^TokenContext) -> bool {
    return  tc.i >= len(tc.tokens)
}

// Check if current token is a macro and has a certain body
@private
tokIsMacroName :: proc(tc: ^TokenContext, name:string) -> bool {
    return tokCurIs(tc, .Macro) && tc.tokens[tc.i].src == name
}

// Get body text of current token and moves to the next. Errors if not text
@private
tokExpectAnyText :: proc(tc: ^TokenContext, errMsg: string) -> string {
    if !tokCurIs(tc, .Text) do errorPos(tokCurPos(tc), errMsg)
    tc.i += 1
    return tc.tokens[tc.i-1].src
}

// Checks that body text of current token is something and moves to the next. Errors if not that text
@private
tokExpectText :: proc(tc: ^TokenContext, text:string, errMsg: string) {
    if !tokCurIs(tc, .Text) || !tokCurText(tc, text) do errorPos(tokCurPos(tc), errMsg)
    tc.i += 1
}

// Gets the index of the next newline, or -1 if no more exsist
@private
tokNextNLIdx :: proc(tc: ^TokenContext) -> int {
    for i := tc.i; i < len(tc.tokens); i += 1 {
        if tc.tokens[i].type == .Newline do return i
    }
    return -1
}

// Resolves (arg, arg, arg) into [dynamic]string or no args into nil
@private
tokResolveArgs :: proc(tc: ^TokenContext, allowDuplicate: bool = true) -> [dynamic]string {
    // Allow @macro (args...)
    if tokCurIs(tc, .Whitespace) && tokNextText(tc, "(") {
        tc.i += 1
    }
    // Only continue if starting args
    if !tokCurText(tc, "(") do return nil
    tc.i += 1
    // Allow leading WS
    tokSkipWS(tc)
    // Allow adding args on new line @macro (\n arg, \n arg, )
    if tokCurIs(tc, .Newline) do tc.i += 1
    args := make([dynamic]string)
    argBuilder : strings.Builder
    defer strings.builder_destroy(&argBuilder)
    for !tokCurText(tc, ")") && !tokIsEmpty(tc) {
        if tokCurIs(tc, .Newline) do errorPos(tokCurPos(tc), "End of line in macro args")
        if tokCurText(tc, ",") {
            // Next argument
            append(&args, strings.clone(strings.to_string(argBuilder)))
            strings.builder_reset(&argBuilder)
            tc.i += 1
            tokSkipWS(tc)
            if tokCurIs(tc, .Newline) do tc.i += 1
        } else if tokCurIs(tc, .Text) {
            strings.write_string(&argBuilder, tc.tokens[tc.i].src)
            tc.i += 1
        } else if tokCurIs(tc, .Whitespace) {
            // Keep WS if passed into a call
            if allowDuplicate && !(tokNextText(tc, ",") || tokNextText(tc, ")")) {
                strings.write_string(&argBuilder, tc.tokens[tc.i].src)                
            }
            tokSkipWS(tc)
            if !allowDuplicate && !tokCurText(tc, ",") && !tokCurText(tc, ")") {
                errorPos(tokCurPos(tc), "Whitespace in macro argument")
            }
        } else if tokCurIs(tc, .Macro) {
            text := resolveMacroCall(tc)
            defer delete(text)
            strings.write_string(&argBuilder,text)
        }
    }
    if strings.trim_space(strings.to_string(argBuilder)) != "" {
        append(&args, 
            strings.clone(strings.to_string(argBuilder))
        )
    }
    // Skip )
    tokExpectText(tc, ")", "Reached end of stream before end of macro args")
    if !allowDuplicate {
        for i := 0; i < len(args) - 1; i += 1 {
            for j := i + 1; j < len(args); j += 1 {
                if i != j && args[i] == args[j] {
                    errorPos(tokCurPos(tc), "Duplicate arguements in macro definition")
                }
            }
        }
    }
    return args
}

// Allows different types of args
TokenArgTypes :: enum {String, Int}
// Arguements can be named for errors
TokenArgTypesAndNames :: struct {value: TokenArgTypes, name: string}
// The values of the types
ArgTypes :: union {string, int}

// Parse arguments with expected count and types
tokArgTypes :: proc(tc: ^TokenContext, errorName: string, argTypes: ..TokenArgTypesAndNames) -> []ArgTypes {
    startPos := tokCurPos(tc)
    args := tokResolveArgs(tc)
    if len(args) != len(argTypes) {
        argNames := slice.mapper(argTypes, proc(t:TokenArgTypesAndNames) -> string {return t.name})
        errorPos(startPos, "%s%s requires %d args but got %d. The args are %s", LEADER, errorName, len(argTypes), len(args), argNames)
    }
    // defer for arg in args do delete(arg)
    defer destroy_args(args)
    ret := make([]ArgTypes, len(args))
    for arg,i in args {
        if argTypes[i].value == .String {
            ret[i] = strings.clone(arg)
        } else if argTypes[i].value == .Int {
            val, ok := strconv.parse_int(arg)
            if !ok {
                errorPos(startPos, "Arg %d of %s (%s) is expected to be an integer", i, errorName, argTypes[i].name)
            }
            ret[i] = val
        } else {
            error("Invalid argument type")
        }
    }
    return ret
}

// Destroys basic arguements
destroy_args_simple :: proc(args: [dynamic]string) {
    if args == nil do return
    for arg in args do delete(arg)
    delete(args)
}

// Destroy complex arguements
destroy_arg_types :: proc(args: []ArgTypes) {
    if args == nil do return
    for arg in args {
        asString, isString := arg.(string)
        if isString do delete(asString)
    }
    delete(args)
}

// Destroy args from tokParseArgs or tokArgTypes
destroy_args :: proc{destroy_arg_types, destroy_args_simple}

// Skips all tokens until reaching an end on the same level of nesting
@private
tokSkipUntilSameLevelEnd :: proc(tc: ^TokenContext, caller: string) {
    // Skip over all body
    endsNeeded := 0
    for (!tokIsMacroName(tc, "end") || endsNeeded != 0) && !tokIsEmpty(tc) {
        if tokIsMacroName(tc, "end") {
            endsNeeded -= 1
        }
        if tokCurIs(tc, .Macro) && slice.any_of(MACROS_WITH_BODIES, tc.tokens[tc.i].src) {
            endsNeeded += 1
        }
        tc.i += 1
    }
    if !tokIsMacroName(tc, "end") {
        // TODO: Record position of calling element and report that instead
        errorPos(tokCurPos(tc), "%s%s does not have an %send", LEADER, caller, LEADER)
    }
    tc.i += 1
}

// Skips all tokens until reaching an end or else on the same level of nesting
@private
tokSkipUntilSameLevelEndOrElse :: proc(tc: ^TokenContext, caller: string) -> (enum {End, Else}) {
    // Skip over all body
    endsNeeded := 0
    for (!(tokIsMacroName(tc, "end") || tokIsMacroName(tc, "else")) || endsNeeded != 0) && !tokIsEmpty(tc) {
        if tokIsMacroName(tc, "end") {
            endsNeeded -= 1
        }
        if tokCurIs(tc, .Macro) && slice.any_of(MACROS_WITH_BODIES, tc.tokens[tc.i].src) {
            endsNeeded += 1
        }
        tc.i += 1
    }
    if !tokIsMacroName(tc, "end") && !tokIsMacroName(tc, "else") {
        // TODO: Record position of calling element and report that instead
        errorPos(tokCurPos(tc), "%s%s does not have an %send", LEADER, caller, LEADER)
    }
    lastTok := tc.tokens[tc.i].src
    tc.i += 1
    return lastTok == "end" ? .End : lastTok == "else" ? .Else : nil
}

@private
MACROS_WITH_BODIES :: []string {
    "ifdef", "notes", "each", "repeat", "if", "define", "eachArg"
}

@private
context_destroy :: proc(tc:^TokenContext) {
    // delete(tc.callerArgs)
    strings.builder_destroy(&tc.out)
    delete(tc.tokens)
    for &frame in tc.stackFrame {
        for _, v in frame.macros {
            for arg in v.args {
                delete(arg)
            }
            delete(v.args)
            if v.body != "" do delete(v.body)
        }
        delete(frame.macros)
        switch cause in frame.cause {
            case FrameEach: {
                for e in cause.elements {
                    delete(e)
                }
                delete(cause.elements)
            }
            case FrameRepeat: {}
            case: {}
        }
    }
    delete(tc.stackFrame)
}

// Takes tokens and input arguements and resolves them to text
@private
resolveTokens :: proc(tokens: [dynamic]Token, inArgs: []string = nil) -> (string, TokenContext) {
    ctx : TokenContext = {
        tokens = tokens, 
        i = 0,
        stackFrame = make([dynamic]Frame),
        callerArgs = inArgs
    }
    // Make root frame
    tokNewFrame(&ctx, nil)
    // Add in args
    for arg, i in inArgs {
        ctx.stackFrame[0].macros[fmt.tprintf("arg%d", i)] = Macro { 
            body = strings.clone(arg) 
        }
    }
    for !tokIsEmpty(&ctx) do switch ctx.tokens[ctx.i].type {
        // When not in a macro, all text is literal
        case .Whitespace, .Text, .Newline: {
            strings.write_string(&ctx.out, ctx.tokens[ctx.i].src)
            ctx.i += 1
        }
        // Handled like statements. These cannot be within macro args
        case .Macro: macroNamePos := tokCurPos(&ctx); switch ctx.tokens[ctx.i].src {
            // These are elements that have to be on the root level
            case "def": {
                // Get name
                ctx.i += 1
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) do errorPos(tokCurPos(&ctx), "End of line reached after def")
                if tokCurIs(&ctx, .Macro)   do errorPos(tokCurPos(&ctx), "Macro names must not start with '%s'", LEADER)
                name  := tokExpectAnyText(&ctx, "Macro names must be text")
                if slice.contains(RESERVED_NAMES, name) {
                    // i - 1 pos because expect moves on
                    errorPos(ctx.tokens[ctx.i - 1].pos, "Tried to redefine reserved macro '@%s'", name)
                }
                macro := Macro {}
                // Check for arguments
                macro.args = tokResolveArgs(&ctx, false)
                tokSkipWS(&ctx)
                // TODO: Collect body till End of Line
                bodyBuilder : strings.Builder
                defer strings.builder_destroy(&bodyBuilder)
                for !tokCurIs(&ctx, .Newline) && !tokIsEmpty(&ctx) {
                    if tokCurIs(&ctx, .Macro) {
                        body := resolveMacroCall(&ctx)
                        defer delete(body)
                        strings.write_string(&bodyBuilder, body)
                        // delete(body)
                    }
                    strings.write_string(&bodyBuilder, ctx.tokens[ctx.i].src)
                    ctx.i += 1
                }
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) do ctx.i += 1
                macro.body = strings.clone(strings.to_string(bodyBuilder))
                ctx.stackFrame[0].macros[name] = macro
            }
            case "define": {
                error("TODO: @define")
                ctx.i += 1
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) do errorPos(tokCurPos(&ctx), "End of line reached after def")
                if tokCurIs(&ctx, .Macro)   do errorPos(tokCurPos(&ctx), "Macro names must not start with '%s'", LEADER)
                name  := tokExpectAnyText(&ctx, "Macro names must be text")
                if slice.contains(RESERVED_NAMES, name) {
                    // i - 1 pos because expect moves on
                    errorPos(ctx.tokens[ctx.i - 1].pos, "Tried to redefine reserved macro '@%s'", name)
                }
                macro := Macro {}
                // Check for arguments
                macro.args = tokResolveArgs(&ctx, false)
                tokSkipWS(&ctx)
                // TODO: Collect body till End of Line
                bodyBuilder : strings.Builder
                defer strings.builder_destroy(&bodyBuilder)
                for !tokIsMacroName(&ctx, "end") && !tokIsEmpty(&ctx) {
                    if tokCurIs(&ctx, .Macro) do strings.write_string(&bodyBuilder, LEADER)
                    strings.write_string(&bodyBuilder, ctx.tokens[ctx.i].src)
                    ctx.i += 1
                }
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) do ctx.i += 1
                macro.body = strings.clone(strings.to_string(bodyBuilder))
                ctx.stackFrame[0].macros[name] = macro
            }
            case "undef": {
                ctx.i += 1
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) {
                    errorPos(macroNamePos, "No macro listed to undefine")
                }
                name := tokExpectAnyText(&ctx, "Expected text for a macro name to undefine")                
                if !tokRemoveMacro(&ctx, name) {
                    when ERR_ON_UNDEF_NONEXISTANT {
                        errorPos(ctx.tokens[ctx.i - 1].pos, "Tried to undefine macro '%s' that doesn't exist", name)
                    }
                } 
                tokSkipIfWSNL(&ctx)
            }
            case "each": {
                ctx.i += 1
                args := tokResolveArgs(&ctx, true)
                if args == nil || len(args) < 1 {
                    errorPos(macroNamePos, "%seach requires at least one argument", LEADER)
                }
                tokBasicFrame(&ctx, args[0], FrameEach {
                    elements = args,
                    index = 0
                })
                ctx.stackFrame[len(ctx.stackFrame) - 1].macros["i"] = Macro {
                    body = fmt.aprintf("0")
                }
                tokSkipIfWSNL(&ctx)
            }
            case "eachArg": {
                ctx.i += 1
                // Expect 0 arguments
                destroy_args(tokArgTypes(&ctx, "eachArg"))
                newArgs := make([dynamic]string)
                if len(inArgs) == 0 {
                    tokSkipUntilSameLevelEnd(&ctx, "eachArg")
                } else {
                    // TODO: Decide if it should eat () and only if empty
                    for arg in inArgs {
                        append(&newArgs, strings.clone(arg))
                    }
                    tokBasicFrame(&ctx, newArgs[0], FrameEach {
                        elements = newArgs,
                        index = 0
                    })
                    ctx.stackFrame[len(ctx.stackFrame) - 1].macros["i"] = Macro {
                        body = fmt.aprintf("0")
                    }
                    tokSkipIfWSNL(&ctx)
                }
            }
            case "repeat": {
                ctx.i += 1
                args := tokArgTypes(&ctx, "repeat", {.Int, "from"}, {.Int, "to"})
                defer destroy_args(args)
                tokBasicFrame(&ctx, fmt.tprintf("%d", args[0]), FrameRepeat {
                    cur = args[0].(int),
                    isInc = args[0].(int) < args[1].(int),
                    to = args[1].(int)
                })
                tokSkipIfWSNL(&ctx)
            }
            case "note": {
                ctx.i += 1
                for !tokCurIs(&ctx, .Newline) && !tokIsEmpty(&ctx) {
                    ctx.i += 1
                }
                if tokCurIs(&ctx, .Newline) do ctx.i += 1
            }
            case "notes": {
                // Ignores everything in between this and @end
                ctx.i += 1
                // Go until @end. Does not allow @notes out sections of macros
                for !tokIsMacroName(&ctx, "end") && !tokIsEmpty(&ctx) {
                    ctx.i += 1
                }
                if !tokIsMacroName(&ctx, "end") {
                    error("Reached eof without finding end for notes")
                }
                ctx.i += 1
                tokSkipIfWSNL(&ctx)
            }
            case "end": {
                if len(ctx.stackFrame) == 1 {
                    errorPos(tokCurPos(&ctx), "%send without a starting block", LEADER)
                }
                frame := &ctx.stackFrame[len(ctx.stackFrame) - 1]
                switch &cause in frame.cause {
                    case FrameEach: {
                        if cause.index < len(cause.elements) - 1 {
                            cause.index += 1
                            // Go back to caller
                            ctx.i = frame.startIndex
                            updateFrameTarget(&ctx, len(ctx.stackFrame) - 1, cause.elements[cause.index])
                            if "i" in ctx.stackFrame[len(ctx.stackFrame) - 1].macros {
                                macro := ctx.stackFrame[len(ctx.stackFrame) - 1].macros["i"]
                                destroy_args(macro.args)
                                delete(macro.body)
                                delete_key(&ctx.stackFrame[len(ctx.stackFrame) - 1].macros, "i")
                            }
                            ctx.stackFrame[len(ctx.stackFrame) - 1].macros["i"] = Macro {
                                body = fmt.aprintf("%d", cause.index)
                            }
                        } else {
                            tokDropFrame(&ctx)
                            // Skip end
                            ctx.i += 1
                            tokSkipWS(&ctx)
                        }
                    }
                    case FrameRepeat: {
                        if cause.isInc && cause.cur < cause.to {
                            cause.cur += 1
                            // Go back to caller
                            ctx.i = frame.startIndex
                            // Update the @@, @_@, and @^@
                            updateFrameTarget(&ctx, len(ctx.stackFrame) - 1, fmt.tprintf("%d", cause.cur))
                        } else if !cause.isInc && cause.cur > cause.to {
                            cause.cur -= 1
                            ctx.i = frame.startIndex
                            updateFrameTarget(&ctx, len(ctx.stackFrame) - 1, fmt.tprintf("%d", cause.cur))
                        } else {
                            tokDropFrame(&ctx)
                            ctx.i += 1
                            tokSkipWS(&ctx)
                        }
                    }
                    case: {
                        // Nothing specific to do, just drop
                        tokDropFrame(&ctx)
                        ctx.i += 1
                        tokSkipWS(&ctx)
                    }
                }
                tokSkipIfWSNL(&ctx)
            }
            case "includeMacros": {
                // Resolve everything then import the macros.
                // Useful for not having whitespace added from 
                ctx.i += 1

                args := tokResolveArgs(&ctx, true)
                if args == nil || len(args) == 0 {
                    errorPos(tokCurPos(&ctx), "%sincludeMacros must have at least 1 arg, (fileToInclude, ...optionalArgs)\n got %s", LEADER, args)
                }
                defer destroy_args(args)
                fileText, fileOK := os.read_entire_file_from_filename(args[0])
                if !fileOK {
                    errorPos(tokCurPos(&ctx), "Could not include file '%s'", args[0])
                }
                defer delete(fileText)
                newTokens     := lexText(transmute(string)(fileText), args[0])
                toAdd, newCtx := resolveTokens(newTokens, args[1:])
                assert(len(newCtx.stackFrame) == 1, "Included context should only have one stack frame")
    
                for name, macro in newCtx.stackFrame[0].macros {
                    ctx.stackFrame[0].macros[name] = macro
                }
                strings.builder_destroy(&newCtx.out)
                delete(newCtx.stackFrame)
                assert(len(newCtx.stackFrame) == 1)
                delete(newCtx.stackFrame[0].macros)
                delete(newCtx.tokens)
                tokSkipIfWSNL(&ctx)
                delete(toAdd)
            }
            case "if": {
                // if (valA, cond, valB)
                errorPos(tokCurPos(&ctx), "TODO: @if")
            }
            case "else": {
                // If (false) will read until the else and manually intervene
                //  this will only occur after if (true) so it should skip over the body
                if len(ctx.stackFrame) == 1 || ctx.stackFrame[len(ctx.stackFrame) - 1].cause != nil {
                    errorPos(tokCurPos(&ctx), "Reached an %selse without a starting if")
                }
                tokSkipUntilSameLevelEnd(&ctx, "else")
                tokDropFrame(&ctx)
            }
            case "ifdef": {
                ctx.i += 1
                args := tokResolveArgs(&ctx, true)
                if len(args) != 1 {
                    errorPos(tokCurPos(&ctx), "%sifdef requires 1 arguement", LEADER)
                }
                defer destroy_args(args)
                tokSkipIfWSNL(&ctx)
                _, exists := tokGetMacro(&ctx, args[0])
                if exists {
                    // Create a new frame and continue
                    tokNewFrame(&ctx, nil)
                } else {
                    // Skip over all body
                    terminator := tokSkipUntilSameLevelEndOrElse(&ctx, "ifdef")
                    if terminator == .Else {
                        ctx.i += 1
                        tokNewFrame(&ctx, nil)
                    }
                    tokSkipIfWSNL(&ctx)
                }
            }
            case FMT_JOIN: {
                // Remove previous whitespace
                for len(ctx.out.buf) > 0 && isWhitespace(ctx.out.buf[len(ctx.out.buf) - 1]) {
                    strings.pop_byte(&ctx.out)
                }
                ctx.i += 1
                // Remove next whitespace
                tokSkipWS(&ctx)
                if tokCurIs(&ctx, .Newline) do ctx.i += 1
            }
            case: {
                res := resolveMacroCall(&ctx)
                defer delete(res)
                strings.write_string(&ctx.out, res)
            }
        }
    }
    if len(ctx.stackFrame) != 1 {
        error("Reached end of input without closing something with @end")
    }
    return strings.clone(strings.to_string(ctx.out)), ctx
}

// Handled like expressions
@private
resolveMacroCall :: proc(tc:^TokenContext) -> string {
    if !tokCurIs(tc, .Macro) do errorPos(tokCurPos(tc), "Trying to resolve a macro call that isn't a macro")
    macroName := tc.tokens[tc.i].src
    // Verify macro exists
    macro, ok := tokGetMacro(tc, macroName)
    macroNamePos := tokCurPos(tc)
    tc.i += 1
    // Resolve default macros
    if !ok do switch macroName {
        // Handle special macros
        case "": {
            args := tokResolveArgs(tc)
            if len(args) == 0 {
                return strings.clone("@")
            }
            // TODO: Could handle this differently?
            error("Undefined behavior of %s(..args)", LEADER)
        }
        case "arg": {
            // Used for allowing referencing arg number using macros
            args := tokArgTypes(tc, "arg", {.Int, "arg number"})
            defer destroy_args(args)
            if args[0].(int) >= len(tc.callerArgs) {
                errorPos(macroNamePos, "Tried to get argument %d, but only %d exist", args[0].(int), len(tc.callerArgs))
            }
            return strings.clone(tc.callerArgs[args[0].(int)])
        }
        case "pad": {
            args := tokResolveArgs(tc, true)
            if len(args) == 2 do append(&args, "0")
            if args == nil || len(args) != 3 {
                errorPos(macroNamePos, "%spad requires 2 or 3 arguments, (toPad, length, padWith='0'), got %d = %s", LEADER, len(args), args)
            }
            defer destroy_args(args)
            arg1, arg1IsNum := strconv.parse_int(args[1])
            if !arg1IsNum {
                errorPos(macroNamePos, "Must use a number to tell length of padding")
            }
            if len(args[2]) != 1 {
                errorPos(macroNamePos, "Cannot pad with more than 1 character")
            }
            return strings.right_justify(args[0], arg1, args[2])
        }
        case "upper": {
            args := tokArgTypes(tc, "upper", {.String, "text"})
            defer destroy_args(args)
            return strings.to_upper(args[0].(string))
        }
        case "lower": {
            args := tokArgTypes(tc, "lower", {.String, "text"})
            defer destroy_args(args)
            return strings.to_lower(args[0].(string))
        }
        case "len": {
            args := tokArgTypes(tc, "len", {.String, "text"})
            defer destroy_args(args)
            return fmt.aprintf("%d", len(args[0].(string)))
        }
        case "trim": {
            args := tokArgTypes(tc, "trim", {.String, "text"})
            defer destroy_args(args)
            return strings.clone(strings.trim_space(args[0].(string)))
        }
        case "replace": {
            args := tokArgTypes(tc, "replace", {.String, "source"}, {.String, "old"}, {.String, "new"})
            defer destroy_args(args)
            repl, wasAlloc := strings.replace_all(args[0].(string), args[1].(string), args[2].(string))
            // Ensure it was allocated
            if wasAlloc do return repl
            return strings.clone(repl)
        }
        case "include": {
            args := tokResolveArgs(tc, true)
            if args == nil || len(args) == 0 {
                errorPos(tokCurPos(tc), "%sinclude must have at least 1 arg, (fileToInclude, ...optionalArgs)\n got %s", LEADER, args)
            }
            defer destroy_args(args)
            fileText, fileOK := os.read_entire_file_from_filename(args[0])
            if !fileOK {
                errorPos(tokCurPos(tc), "Could not include file '%s'", args[0])
            }
            defer delete(fileText)
            newTokens     := lexText(transmute(string)(fileText), args[0])
            toAdd, newCtx := resolveTokens(newTokens, args[1:])
            assert(len(newCtx.stackFrame) == 1, "Included context should only have one stack frame")

            for name, innerMacro in newCtx.stackFrame[0].macros {
                tc.stackFrame[0].macros[name] = innerMacro
            }
            strings.builder_destroy(&newCtx.out)
            delete(newCtx.stackFrame)
            assert(len(newCtx.stackFrame) == 1)
            delete(newCtx.stackFrame[0].macros)
            delete(newCtx.tokens)
            tokSkipIfWSNL(tc)
            return toAdd
        }
        case "includeRaw": {
            args := tokResolveArgs(tc, true)
            if args == nil || len(args) != 1 {
                errorPos(tokCurPos(tc), "%sincludeRaw must have 1 arg, (fileToInclude)")
            }
            defer destroy_args(args)
            fileText, fileOK := os.read_entire_file_from_filename(args[0])
            if !fileOK {
                errorPos(tokCurPos(tc), "Could not include file '%s'", args[0])
            }
            defer delete(fileText)
            // Remove pesky windows \r
            noCR, didAlloc := strings.replace_all(transmute(string)(fileText), "\r", "")
            defer if didAlloc do delete(noCR)
            tokSkipIfWSNL(tc)
            return strings.clone(noCR)
        }
        case FMT_NEWLINE: {
            // We make sure to allocate everything leaving this function
            //  so that we can delete it all after
            // We allow arguments, i.e. () after macro for chaining macros
            args := tokResolveArgs(tc, true)
            defer destroy_args(args)
            if len(args) != 0 do error("Newline macro takes no arguments")
            return strings.clone("\n")
        }
        case: {
            errorPos(macroNamePos, "Unknown macro '%s'", macroName)
        }
    } 
    // Resolve defined macros
    callerArgs := tokResolveArgs(tc, true)
    defer destroy_args(callerArgs)
    if len(callerArgs) != len(macro.args) {
        errorPos(macroNamePos, "Macro '%s' requires %d argument%s, but got %d instead", 
            macroName, len(macro.args), len(macro.args) == 1 ? "" : "s",
            len(callerArgs)
        )
    }
    preWrite : strings.Builder
    defer strings.builder_destroy(&preWrite)
    strings.write_string(&preWrite, macro.body)
    for _, i in callerArgs {
        toWrite, didAlloc := strings.replace_all(strings.to_string(preWrite), macro.args[i], callerArgs[i])
        defer if didAlloc do delete(toWrite)
        strings.builder_reset(&preWrite)
        strings.write_string(&preWrite, toWrite)
    }
    return strings.clone(strings.to_string(preWrite))
}
