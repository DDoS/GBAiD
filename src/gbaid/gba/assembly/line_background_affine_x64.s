    mov EAX, cx
    push RAX
    mov EBX, cy
    push RBX
    push lineAddress
    push 0
loop:
    ; calculate x
    sar EAX, 8
    ; calculate y
    sar EBX, 8
    ; EAX = x, EBX = y
    ; check and handle overflow
    mov ECX, bgSizeInv
    test EAX, ECX
    jz skip_x_overflow
    test overflowWrapAround, 1
    jnz skip_transparent1
    mov CX, TRANSPARENT
    jmp end_color
skip_transparent1:
    and EAX, bgSize
skip_x_overflow:
    test EBX, ECX
    jz skip_y_overflow
    test overflowWrapAround, 1
    jnz skip_transparent2
    mov CX, TRANSPARENT
    jmp end_color
skip_transparent2:
    and EBX, bgSize
skip_y_overflow:
    ; check and apply mosaic
    test mosaicEnabled, 1
    jz skip_mosaic
    push RBX
    mov EBX, EAX
    xor EDX, EDX
    mov ECX, mosaicSizeX
    add ECX, 1
    div ECX
    sub EBX, EDX
    pop RAX
    push RBX
    mov EBX, EAX
    xor EDX, EDX
    mov ECX, mosaicSizeY
    add ECX, 1
    div ECX
    sub EBX, EDX
    pop RAX
skip_mosaic:
    ; calculate the map address
    push RAX
    push RBX
    shr EAX, 3
    shr EBX, 3
    mov ECX, mapLineShift
    shl EBX, CL
    add EAX, EBX
    add EAX, mapBase
    add RAX, vramAddress
    ; get the tile number
    xor ECX, ECX
    mov CL, [RAX]
    ; calculate the tile address
    pop RBX
    pop RAX
    and EAX, 7
    and EBX, 7
    shl EBX, 3
    add EAX, EBX
    shl ECX, 6
    add EAX, ECX
    add EAX, tileBase
    add RAX, vramAddress
    ; get the palette index
    xor EDX, EDX
    mov DL, [RAX]
    ; calculate the palette address
    shl EDX, 1
    jnz end_palettes
    mov CX, TRANSPARENT
    jmp end_color
end_palettes:
    ; ECX = paletteAddress
    ; get color from palette
    add RDX, paletteAddress
    mov CX, [RDX]
    and ECX, 0x7FFF
end_color:
    ; ECX = color
    pop RAX
    pop RBX
    ; EAX = index, EBX = buffer address
    ; write color to line buffer
    mov [RBX], CX
    pop RDX
    pop RCX
    ; ECX = cx, EDX = cy
    ; check loop condition
    cmp EAX, 239
    jge end
    ; increment cx and cy
    add ECX, pa
    push RCX
    add EDX, pc
    push RDX
    ; increment address and counter
    add RBX, 2
    push RBX
    add EAX, 1
    push RAX
    ; prepare for next iteration
    mov EAX, ECX
    mov EBX, EDX
    jmp loop
end:
    nop
