; Do the subtraction and save the flags to EBX
mov EAX, op1
sub EAX, op2
pushfq
pop RBX
; Place the zero and sign flags at bits 2 and 3 of ECX
mov ECX, EBX
and ECX, 0b1100_0000
shr ECX, 4
; Place the carry flag at bit 1 of ECX (invert the borrow flag)
mov EDX, EBX
not EDX
and EDX, 0b1
shl EDX, 1
or ECX, EDX
; Place the overflow flag at bit 0 of ECX
and EBX, 0b1000_0000_0000
shr EBX, 11
or ECX, EBX
; Place the result in the output variables
mov res, EAX
mov flags, ECX
