; KAGURA-6502 platform code for msbasic (assembled after the interpreter).
;   - image header (segment KHDR, first 16 bytes of the image at BASIC_BASE)
;   - ISCNTC (Ctrl-C check, called between statements), LOAD, SAVE
; The extension commands of the design in docs/basic-extension-design.md will be
; added here (dispatch through BIOS_EXT); nothing else in msbasic needs changing.

; ---- image header: checksum is filled in by mkimage.py after linking -------------
.import __KIMAGE_END__, __CODE_LOAD__, __CODE_RUN__, __CODE_SIZE__
.segment "KHDR"
        .byte   "K65BASIC"
        .word   COLD_START              ; cold start (asks MEMORY SIZE / TERMINAL WIDTH)
        .word   __KIMAGE_END__          ; end of the image (linker symbol)
        .word   $0000                   ; checksum placeholder (mkimage.py)
        .word   RESTART                 ; warm start
        .word   __CODE_LOAD__           ; boot-time copy of the CODE segment
        .word   __CODE_RUN__            ;   (load = run in the PSRAM-only image -> no copy)
        .word   __CODE_SIZE__
        .word   $0000

.segment "EXTRA"
; ---- Ctrl-C: called by NEWSTT before every statement ------------------------------
; Same contract as the KIM-1 ISCNTC: return if no Ctrl-C, otherwise enter STOP with
; C=1 (cmp #$03 with A=$03 sets C and Z). Other keys typed during RUN are consumed,
; as on the KIM-1.
ISCNTC:
        jsr     BIOS_CHRIN_NB
        bcc     @none
        cmp     #$03
        bne     @none
        jmp     STOP
@none:  rts

; ---- LOAD / SAVE: BIOS services (stubs in the PoC) ---------------------------------
LOAD:   jmp     BIOS_LOAD
SAVE:   jmp     BIOS_SAVE
