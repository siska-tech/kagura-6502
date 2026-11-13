; KAGURA-6502 BIOS for the BASIC proof of concept (ca65, W65C02S).
; Lives in the Boot ROM (BSRAM). Responsibilities:
;   1. reset: stack, console banner, progress signatures ($D003)
;   2. find the BASIC image in PSRAM (header at BASIC_BASE, 16-bit checksum),
;      write-protect it ($D00C) and jump to its cold-start entry
;   3. without a valid image: a binary loader on the console UART so that the
;      image (or any program) can be put into PSRAM over the same cable
;   4. console services for BASIC through a fixed jump table at $FF00
;
; Loader frames (host -> KAGURA, all binary, little endian):
;   'L' addr16 len16 data[len] sum16   load; reply "OK"/"ER" + CR LF (sum = 16-bit byte sum of data)
;   'B'                                 check the BASIC image again and start it
;   'G' addr16                          jump to addr
; Anything else is ignored. The loader writes with the PSRAM write protect off.
;
; Signatures written to IO_SIG ($D003): A5 reset, B5 image ok -> BASIC,
; E1 no / bad image (loader), E2 load frame checksum error.

        .setcpu "65C02"
        .include "kagura.inc"

PTR     = BIOS_ZP+0             ; 2 bytes
SUM     = BIOS_ZP+2             ; 2 bytes
CNT     = BIOS_ZP+4             ; 2 bytes
TMP     = BIOS_ZP+6

        .segment "BIOS"
; ----------------------------------------------------------------------------
reset:  sei
        cld
        ldx     #$FF
        txs
        lda     #$A5
        sta     IO_SIG
        stz     PS_WP                   ; image may be reloaded after a warm reset
        lda     CON_STAT                ; clear a stale RX overrun flag
        ldx     #<msg_banner
        ldy     #>msg_banner
        jsr     puts
.ifdef VDP
        jsr     vdp_init                ; VRAM is not initialised by the FPGA configuration
.endif
boot:   jsr     check_image
        bcc     noimg
        jsr     boot_copy               ; header copy descriptor (e.g. CODE -> fast RAM)
        lda     #>BASIC_BASE
        sta     PS_WP                   ; interpreter image becomes read-only
        lda     #$B5
        sta     IO_SIG
        jmp     (HDR_COLD)
noimg:  lda     #$E1
        sta     IO_SIG
        ldx     #<msg_noimg
        ldy     #>msg_noimg
        jsr     puts
        ; fall into the loader

; ----------------------------------------------------------------------------
loader: jsr     chrin
        cmp     #'L'
        beq     ld_frame
        cmp     #'B'
        beq     boot
        cmp     #'G'
        bne     loader
        jsr     get16                   ; PTR = target
        jmp     (PTR)

ld_frame:
        jsr     get16                   ; PTR = address
        lda     PTR
        sta     CNT
        lda     PTR+1
        sta     CNT+1
        jsr     get16                   ; PTR = length
        lda     PTR                     ; swap: PTR = address, CNT = length
        ldx     CNT
        sta     CNT
        stx     PTR
        lda     PTR+1
        ldx     CNT+1
        sta     CNT+1
        stx     PTR+1
        stz     SUM
        stz     SUM+1
        stz     PS_WP
@lp:    lda     CNT
        ora     CNT+1
        beq     @done
        jsr     chrin
        sta     (PTR)
        clc
        adc     SUM
        sta     SUM
        bcc     :+
        inc     SUM+1
:       inc     PTR
        bne     :+
        inc     PTR+1
:       lda     CNT
        bne     :+
        dec     CNT+1
:       dec     CNT
        jmp     @lp
@done:  jsr     chrin
        cmp     SUM
        bne     @bad1
        jsr     chrin
        cmp     SUM+1
        bne     @bad
        ldx     #<msg_ok
        ldy     #>msg_ok
        jsr     puts
        jmp     loader
@bad1:  jsr     chrin                   ; consume the high byte
@bad:   lda     #$E2
        sta     IO_SIG
        ldx     #<msg_er
        ldy     #>msg_er
        jsr     puts
        jmp     loader

get16:  jsr     chrin
        sta     PTR
        jsr     chrin
        sta     PTR+1
        rts

; ----------------------------------------------------------------------------
; boot_copy: copy HDR_CLEN bytes from HDR_CSRC to HDR_CDST (forward, no overlap);
; nothing if the length is 0 or source = destination
boot_copy:
        lda     HDR_CSRC
        sta     PTR
        cmp     HDR_CDST
        bne     @go
        lda     HDR_CSRC+1
        cmp     HDR_CDST+1
        beq     @ret
@go:    lda     HDR_CSRC+1
        sta     PTR+1
        lda     HDR_CDST
        sta     SUM                     ; SUM = destination pointer here
        lda     HDR_CDST+1
        sta     SUM+1
        lda     HDR_CLEN
        sta     CNT
        ldx     HDR_CLEN+1              ; X = whole pages
        ldy     #0
        txa
        beq     @part
@pg:    lda     (PTR),y
        sta     (SUM),y
        iny
        bne     @pg
        inc     PTR+1
        inc     SUM+1
        dex
        bne     @pg
@part:  cpy     CNT
        beq     @ret
        lda     (PTR),y
        sta     (SUM),y
        iny
        bra     @part
@ret:   rts

; ----------------------------------------------------------------------------
; check_image: C=1 if the header magic, range and checksum are valid
check_image:
        ldx     #7
@mg:    lda     BASIC_BASE,x
        cmp     magic,x
        bne     @no
        dex
        bpl     @mg
        lda     HDR_END+1               ; BASIC_BASE < end <= BASIC_LIMIT
        cmp     #>BASIC_BASE
        bcc     @no
        cmp     #>BASIC_LIMIT
        bcc     @rng
        bne     @no
        lda     HDR_END
        bne     @no
@rng:   lda     HDR_END                 ; end -> CNT (zero page: no PSRAM read per byte)
        sta     CNT
        lda     HDR_END+1
        sta     CNT+1
        lda     #<(BASIC_BASE+HDR_LEN)
        sta     PTR
        lda     #>(BASIC_BASE+HDR_LEN)
        sta     PTR+1
        stz     SUM
        stz     SUM+1
        ldy     #0
@sm:    lda     PTR                     ; while PTR != end
        cmp     CNT
        bne     @add
        lda     PTR+1
        cmp     CNT+1
        beq     @cmp
@add:   lda     (PTR),y
        clc
        adc     SUM
        sta     SUM
        bcc     :+
        inc     SUM+1
:       inc     PTR
        bne     @sm
        inc     PTR+1
        bra     @sm
@cmp:   lda     SUM
        cmp     HDR_SUM
        bne     @no
        lda     SUM+1
        cmp     HDR_SUM+1
        bne     @no
        sec
        rts
@no:    clc
        rts

; ----------------------------------------------------------------------------
; console
chrin:  lda     CON_STAT
        lsr     a                       ; b0 -> C
        bcc     chrin
        lda     CON_DATA
        rts

chrin_nb:
        lda     CON_STAT
        lsr     a
        bcc     :+
        lda     CON_DATA                ; C still 1
:       rts

chrout: pha
:       lda     CON_STAT
        and     #$02
        beq     :-
        pla
        sta     CON_DATA
        rts

; BASIC line-input key: upper case, BS/DEL -> '_', echo printable characters
; (MS BASIC does not echo; it prints CR LF itself after the RETURN key)
rdkey:  jsr     chrin
        cmp     #$08
        beq     @del
        cmp     #$7F
        beq     @del
        cmp     #'a'
        bcc     @echo
        cmp     #'z'+1
        bcs     @echo
        and     #$DF
@echo:  cmp     #$20
        bcc     @ret
        cmp     #$7F
        bcs     @ret
        jsr     chrout
@ret:   rts
@del:   lda     #'_'
        bra     @echo

; puts: X/Y = address of a NUL-terminated string
puts:   stx     PTR
        sty     PTR+1
        ldy     #0
:       lda     (PTR),y
        beq     :+
        jsr     chrout
        iny
        bne     :-
:       rts

load_stub:
save_stub:
        ldx     #<msg_nodev
        ldy     #>msg_nodev
        jmp     puts

.ifdef VDP
; ----------------------------------------------------------------------------
; vdp_init (VDP builds only): clear the tile map ($08000, 4 KiB), the OAM ($09000,
; 2 KiB: every sprite disabled) and pattern 0 (32 bytes), border 0 (black), CTRL 3.
; 6,176 VDATA writes, about 9 CPU cycles each (~16 ms at 3.375 MHz).
vdp_init:
        stz     VDP_BORDER
        lda     #$03
        sta     VDP_CTRL
        lda     #1
        sta     VDP_VINC
        lda     #$80                    ; map: $08000, 16 pages
        ldx     #16
        jsr     @clr
        lda     #$90                    ; OAM: $09000, 8 pages
        ldx     #8
        jsr     @clr
        stz     VDP_VADDR0              ; pattern 0: 32 bytes
        stz     VDP_VADDR1
        stz     VDP_VADDR2
        ldy     #32
:       stz     VDP_VDATA
        dey
        bne     :-
        rts
@clr:   stz     VDP_VADDR0              ; A = address bits 15..8, X = pages
        sta     VDP_VADDR1
        stz     VDP_VADDR2
        ldy     #0
:       stz     VDP_VDATA
        dey
        bne     :-
        dex
        bne     :-
        rts
.endif

; extension dispatcher (Phase 5 design: X = function, A/Y = arguments). None yet.
ext:    sec                             ; C=1: function not implemented
        rts

irq:    pha
        lda     IO_IRQ
        sta     IO_IRQ                  ; ack (BASIC does not use IRQs in the PoC)
        pla
nmi:    rti

magic:      .byte   "K65BASIC"
msg_banner: .byte   13, 10, "KAGURA-6502 BIOS 0.1", 13, 10, 0
msg_noimg:  .byte   "NO BASIC IMAGE - LOADER READY", 13, 10, 0
msg_ok:     .byte   "OK", 13, 10, 0
msg_er:     .byte   "ER", 13, 10, 0
msg_nodev:  .byte   "?NO DEVICE", 13, 10, 0

; ----------------------------------------------------------------------------
        .segment "JUMPTAB"              ; $FF00, stable ABI (kagura.inc)
        jmp     chrin                   ; $FF00 BIOS_CHRIN
        jmp     chrout                  ; $FF03 BIOS_CHROUT
        jmp     chrin_nb                ; $FF06 BIOS_CHRIN_NB
        jmp     rdkey                   ; $FF09 BIOS_RDKEY
        jmp     load_stub               ; $FF0C BIOS_LOAD
        jmp     save_stub               ; $FF0F BIOS_SAVE
        jmp     ext                     ; $FF12 BIOS_EXT

        .segment "VECTORS"
        .word   nmi
        .word   reset
        .word   irq
