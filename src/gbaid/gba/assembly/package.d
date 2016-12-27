module gbaid.gba.assembly;

import std.exception : assumeUnique;

version (D_InlineAsm_X86_64) {
    public enum string LINE_BACKGROUND_TEXT_ASM = "asm {"
        ~ import("line_background_text_x64.s").convertToDASM() ~
    "}";
    public enum string LINE_BACKGROUND_AFFINE_ASM = "asm {"
        ~ import("line_background_affine_x64.s").convertToDASM() ~
    "}";
} else version (D_InlineAsm_X86) {
    public enum string LINE_BACKGROUND_TEXT_ASM = "asm {"
        ~ import("line_background_text_x64.s").x64_to_x86().convertToDASM() ~
    "}";
    public enum string LINE_BACKGROUND_AFFINE_ASM = "asm {"
        ~ import("line_background_affine_x64.s").x64_to_x86().convertToDASM() ~
    "}";
}

private string convertToDASM(string rawAsm) {
    return rawAsm.removeComments().addSemiColons();
}

private string removeComments(inout char[] asmStr) {
    char[] noComments;
    auto ignore = false;
    foreach (c; asmStr) {
        if (c == ';') {
            ignore = true;
        } else if (c == '\r' || c == '\n') {
            ignore = false;
        }
        if (!ignore) {
            noComments ~= c;
        }
    }
    return noComments.assumeUnique();
}

private string addSemiColons(inout char[] asmStr) {
    char[] withSemiColons = [asmStr[0]];
    foreach (i, c; asmStr[1 .. $]) {
        withSemiColons ~= c;
        if (c == '\n' && asmStr[i - 1] != ':') {
            withSemiColons ~= ';';
        }
    }
    return withSemiColons.assumeUnique();
}

// Very basic conversion for the purpose of this project only
// Only converts 64 registers to 32 bit
private string x64_to_x86(inout char[] x64) {
    size_t length = x64.length;
    char[] x86;
    x86.length = length;
    foreach (i; 0 .. length - 2) {
        if (x64[i] == 'R' && x64[i + 2] == 'X') {
            char c = x64[i + 1];
            if (c == 'A' || c == 'B' || c == 'C' || c == 'D') {
                x86[i] = 'E';
                continue;
            }
        }
        x86[i] = x64[i];
    }
    x86[length - 1] = x64[length - 1];
    x86[length - 2] = x64[length - 2];
    return x86.assumeUnique;
}
