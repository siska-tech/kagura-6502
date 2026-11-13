; KAGURA-6502 BASIC platform: shared constants (ca65). Used by the BIOS (bios.s)
; and by the msbasic platform layer (kagura/). One place for the memory map,
; the I/O registers and the BIOS entry points.
;
; ---- memory map (54 MHz, fast RAM 8 KiB build; the 2 KiB build only moves the
;      fast/PSRAM boundary, software sees the same addresses) -------------------
;   $0000-$00FF  zero page   (BASIC: see zeropage use in docs; BIOS: BIOS_ZP..$FF)
;   $0100-$01FF  stack
;   $0200-$02FF  BIOS work area
;   $0300-...    BASIC program text / variables / arrays (grows up)
;   ...-BASIC_BASE-1  BASIC strings (grow down from MEMSIZ = BASIC_BASE)
;   BASIC_BASE-$BFFF  BASIC interpreter image in PSRAM, write-protected ($D00C)
;   $C000-$CFFF  PSRAM bank window
;   $D000-$D00F  I/O
;   $E000-$EFFF  PSRAM (free; reserved for BASIC extensions / BIOS RAM services)
;   $F000-$FFFF  Boot ROM (BIOS), BSRAM
BASIC_BASE      = $9800         ; image header + interpreter (must be page aligned)
BASIC_LIMIT     = $C000         ; image must end below this
; first byte of BASIC program memory: $0300 for the image that runs entirely from
; PSRAM; $2000 for the "fastcode" image whose CODE segment is copied to $0300-$1FFF
.ifdef FASTCODE
RAMSTART        = $2000
.else
RAMSTART        = $0300
.endif

; ---- BASIC image header (24 bytes at BASIC_BASE) -------------------------------
;   +0  "K65BASIC"   magic
;   +8  .word cold   cold-start entry
;   +10 .word end    first byte after the image
;   +12 .word sum    16-bit sum of all bytes in [BASIC_BASE+HDR_LEN, end)
;   +14 .word warm   warm-start entry
;   +16 .word src    boot-time copy: source (in the image), destination, length.
;   +18 .word dst    The BIOS copies before starting BASIC (e.g. interpreter code
;   +20 .word len    into fast RAM). len = 0 or src = dst: no copy.
;   +22 .word 0      reserved
HDR_LEN         = 24
HDR_COLD        = BASIC_BASE+8
HDR_END         = BASIC_BASE+10
HDR_SUM         = BASIC_BASE+12
HDR_WARM        = BASIC_BASE+14
HDR_CSRC        = BASIC_BASE+16
HDR_CDST        = BASIC_BASE+18
HDR_CLEN        = BASIC_BASE+20

; ---- I/O ($D000-$D00F) -----------------------------------------------------------
IO_IRQ          = $D000         ; R: b7 IRQ pending, b0 READY / W: ack
IO_LED          = $D001
IO_PSRDY        = $D002         ; R: b0 PSRAM initialised
IO_SIG          = $D003         ; progress signature (testbench / LEDs / status frame)
IO_ROMWP        = $D004
IO_BANKL        = $D005
IO_BANKH        = $D006
IO_TMREN        = $D009
CON_DATA        = $D00A         ; console UART: W send / R pop RX FIFO
CON_STAT        = $D00B         ; b0 RX avail, b1 TX ready, b2 RX overrun (clear on read)
PS_WP           = $D00C         ; first write-protected PSRAM page (0 = off), up to $BFFF

; ---- VDP ($D300-$D33F, fpga/vdp, docs/vdp-320x176.md) --------------------------------
VDP_VADDR0      = $D300         ; VRAM address bits 7..0
VDP_VADDR1      = $D301         ;              bits 15..8
VDP_VADDR2      = $D302         ;              bit 16; writing it starts the prefetch
VDP_VDATA       = $D303         ; VRAM data, address += VINC after each access
VDP_VINC        = $D304
VDP_CTRL        = $D305         ; b0 BG, b1 sprites, b7 VBLANK IRQ enable
VDP_STATUS      = $D306         ; b7 VBLANK, b6 sprite overflow (clear on read), b0 busy
VDP_BORDER      = $D307         ; b3..0 palette-0 index, b7 0 = frame latch / 1 = per line
VDP_SCXL        = $D308
VDP_SCXH        = $D309
VDP_SCY         = $D30A
VDP_LINE        = $D30B
VDP_PATCNTL     = $D30C
VDP_PATCNTH     = $D30D

; ---- BIOS entry points (jump table at $FF00, stable ABI) ---------------------------
BIOS_CHRIN      = $FF00         ; A = next console byte (blocking). X, Y preserved
BIOS_CHROUT     = $FF03         ; send A. A, X, Y preserved
BIOS_CHRIN_NB   = $FF06         ; C=1: A = byte; C=0: none. X, Y preserved
BIOS_RDKEY      = $FF09         ; BASIC line input key: blocking, upper case, echoed,
                                ; BS/DEL -> '_' (MS BASIC "delete last char"). X, Y preserved
BIOS_LOAD       = $FF0C         ; LOAD service (stub in the PoC: prints ?NO DEVICE)
BIOS_SAVE       = $FF0F         ; SAVE service (stub in the PoC)
BIOS_EXT        = $FF12         ; extension dispatcher: X = function number (see docs)

; ---- BIOS zero page (top of ZP; msbasic KAGURA build does not use $F0-$FF) --------
BIOS_ZP         = $F0
