    push lineAddress
    mov EAX, 0
    push RAX
loop:
    ; calculate x for entire bg
    add EAX, xOffset
    and EAX, totalWidth
    ; start calculating tile address
    mov EDX, mapBase
    ; calculate x for section
    test EAX, ~255
    jz skip_overflow
    and EAX, 255
    add EDX, 2048
skip_overflow:
    test mosaicEnabled, 1
    jz skip_mosaic
    ; apply horizontal mosaic
    push RDX
    xor EDX, EDX
    mov EBX, EAX
    mov ECX, mosaicSizeX
    add ECX, 1
    div ECX
    sub EBX, EDX
    mov EAX, EBX
    pop RDX
skip_mosaic:
    ; EAX = x, RDX = map
    mov EBX, EAX
    ; calculate tile map and column
    shr EBX, 3
    and EAX, 7
    ; calculate map address
    add EBX, lineMapOffset
    shl EBX, 1
    add EDX, EBX
    add RDX, vramAddress
    ; get tile
    xor EBX, EBX
    mov BX, [RDX]
    ; EAX = tileColumn, EBX = tile
    mov ECX, EAX
    ; calculate sample column and line
    test EBX, 0x400
    jz skip_hor_flip
    not ECX
    and ECX, 7
skip_hor_flip:
    mov EDX, tileLine
    test EBX, 0x800
    jz skip_ver_flip
    not EDX
    and EDX, 7
skip_ver_flip:
    ; EBX = tile, ECX = sampleColumn, EDX = sampleLine
    push RCX
    ; calculate tile address
    shl EDX, 3
    add EDX, ECX
    mov ECX, tile4Bit
    shr EDX, CL
    mov EAX, EBX
    and EAX, 0x3FF
    mov ECX, tileSizeShift
    shl EAX, CL
    add EAX, EDX
    add EAX, tileBase
    add RAX, vramAddress
    pop RCX
    ; EAX = tileAddress, EBX = tile, ECX = sampleColumn
    ; calculate the palette address
    mov DL, [RAX]
    test singlePalette, 1
    jz mult_palettes
    and EDX, 0xFF
    jnz skip_transparent1
    mov CX, TRANSPARENT
    jmp end_color
skip_transparent1:
    shl EDX, 1
    jmp end_palettes
mult_palettes:
    and ECX, 1
    shl ECX, 2
    shr EDX, CL
    and EDX, 0xF
    jnz skip_transparent2
    mov CX, TRANSPARENT
    jmp end_color
skip_transparent2:
    shr EBX, 8
    and EBX, 0xF0
    add EDX, EBX
    shl EDX, 1
end_palettes:
    ; EDX = paletteAddress
    ; get color from palette
    add RDX, paletteAddress
    mov CX, [RDX]
    and ECX, 0x7FFF
end_color:
    ; ECX = color
    pop RAX
    pop RBX
    ; write color to line buffer
    mov [RBX], CX
    ; check loop condition
    cmp EAX, 239
    jge end
    ; increment address and counter
    add RBX, 2
    push RBX
    add EAX, 1
    push RAX
    jmp loop
end:
    nop
