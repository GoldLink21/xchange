package xchange

import "core:testing"
import "core:strings"

@(private="file")
T :: ^testing.T
@(private="file")
okTest :: #force_inline proc (t:T, input, expectedOutput: string, loc:=#caller_location) {
    generated, ok := parseText(input)
    defer delete(generated)
    testing.expect(t, ok)
    genReplace, didGenReplaceAlloc := strings.replace_all(generated, "\n", "\\n")
    defer if didGenReplaceAlloc do delete(genReplace)
    outReplace, didOutReplaceAlloc := strings.replace_all(expectedOutput, "\n", "\\n")
    defer if didOutReplaceAlloc do delete(outReplace)
    testing.expectf(t, generated == expectedOutput, "Expected '%s' = '%s'", genReplace, outReplace, loc=loc)
}

@(private="file")
okArgTest :: proc(t:T, input: string, inArgs: []string, expectedOutput: string, loc:=#caller_location) {
    generated, ok := parseText(input, ".", ..inArgs)
    defer delete(generated)
    testing.expect(t, ok)
    genReplace, didGenReplaceAlloc := strings.replace_all(generated, "\n", "\\n")
    defer if didGenReplaceAlloc do delete(genReplace)
    outReplace, didOutReplaceAlloc := strings.replace_all(expectedOutput, "\n", "\\n")
    defer if didOutReplaceAlloc do delete(outReplace)
    testing.expectf(t, generated == expectedOutput, "Expected '%s' = '%s'", genReplace, outReplace, loc=loc)
 
}

@(test)
testPlain :: proc(t:T) {
    okTest(t, "", "")
    okTest(t, "abc", "abc")
    okTest(t, "\\@", "@")
    okTest(t, "@N",   "\n")
    okTest(t, "@N()", "\n")
    okTest(t, "A \n  @~  \t B", "AB")
    okTest(t, "  \t\n", "  \t\n")
    // Plain @ is an @ char
    okTest(t, "Don't @ me", "Don't @ me")
    // @ in the middle does not matter
    okTest(t, "h@k3r M4n", "h@k3r M4n")
    // TODO: Maybe this should be something else?
    okTest(t, "@()", "@")
}


@(test)
testSimpleMacros :: proc(t:T) {
    okTest(t, "@upper(\naBc,\n)", "ABC")
    // This is not okay?
    // okTest(t, "@upper(\naBc\n)", "ABC")

    okTest(t, "@lower(dEf)", "def")
    okArgTest(t, "@arg(0)",{"This is arg 0"}, "This is arg 0")
    okArgTest(t, "@arg(0) @arg(1)",{"Zero", "One"}, "Zero One")
    okTest(t, "@len(this is 16 chars)", "16")
    // Macro defs should not leave any text behind
    okTest(t, "@def A(b) <b>\n", "")
    okTest(t, "@include(testing/spaced.txt)", "  Text with spaces around it   ")
    okTest(t, "@include(testing/sampleMacros.txt)\n@Macro(1234)","<1234>")
    okTest(t, "@note words are not here", "")
    okTest(t, "@include(testing/macros_with_text.txt)", "Text between @A and @B\n")
    okTest(t, "@replace(a1b1c1d1,1,2)", "a2b2c2d2")
    okTest(t, "@includeRaw(testing/sampleMacros.txt)\n", "@def Macro(abcd) <abcd>\n")
}

@test
testMacroNesting :: proc(t:T) {
    okTest(t, "@trim(@includeRaw(testing/spaced.txt))", "Text with spaces around it")
    okTest(t, "@pad(@lower(ABC), 5, G)", "GGabc")
}

@test
testMacroCalls :: proc(t:T) {
    okTest(t, "@def A(b) <b>\n@A(1)", "<1>")
    okTest(t, 
`@def A(x) My name is x
@A(what)@A(who)`,
`My name is whatMy name is who`
    )
    okTest(t, "@includeMacros(testing/macros_with_text.txt)\n@A(g)", "(g)")

}

@test
testBlockMacros :: proc(t:T) {
    // @end should skip whitespace and newlines if they are at the end of the line
    okTest(t, "@notes ABC\nDEF\nGHI\n@end  \n", "")
    okTest(t, "@each(  a  , b,c  )@0()@end", "abc")
    okTest(t, "@repeat(1,5)@0 @end", "1 2 3 4 5 ")
    okTest(t, "@each(c,d,e,f,g)@end", "")
    okTest(t, "@each(c,d,e,f,g)@0()@end", "cdefg")
    okTest(t, "@each(c,d,e,f,g)@0()@i()@end", "c0d1e2f3g4")
    okArgTest(t, "@eachArg()@0 @end", {"a", "b", "c"}, "a b c ")
}

@test
testConditionals :: proc(t:T) {
    okTest(t, 
`@def A(x) My name is x
@ifdef(A)
Defined
@end`,
`Defined
`
    )
    okTest(t, 
`@ifdef(A)
Defined
@end`,
``)
    okTest(t, 
`@ifdef(A)
Defined
@else
Not Defined
@end`,
`Not Defined
`)
}

@test
testNestedBlocks :: proc(t:T) {
    okArgTest(t, "@eachArg()@eachArg()(@0()@1)@end @end", 
        {"a", "b", "c"}, 
        "(aa)(ab)(ac)(ba)(bb)(bc)(ca)(cb)(cc)"
    )
    okTest(t, "@each(a,b,c)@each(1,2,3)(@0()@1)@end @end", 
        "(a1)(a2)(a3)(b1)(b2)(b3)(c1)(c2)(c3)"
    )
}
