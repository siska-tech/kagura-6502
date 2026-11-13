; KAGURA-6502 platform definitions for mist64/msbasic (third_party/msbasic, unmodified).
; Base: the KIM-1 configuration (defines_kim.s) = Microsoft BASIC 1.1, the version
; Microsoft released under the MIT license (microsoft/BASIC-M6502, REALIO=1 KIM).
; Differences from KIM-1 (all are I/O or memory-layout choices, no interpreter change):
;   - ROM-style build (no CONFIG_RAM): the image is write-protected in PSRAM and is
;     not reclaimed by the RAM version's "WANT SIN-COS-TAN-ATN" trick
;   - no CONFIG_ROR_WORKAROUND (the W65C02S has a working ROR)
;   - console calls go to the KAGURA BIOS, which preserves Y (no CONFIG_MONCOUT_DESTROYS_Y)
;   - no NULL statement (paper-tape padding)
;   - program memory starts at RAMSTART (kagura.inc), not after the code

        .include "../kagura.inc"

; configuration
CONFIG_11A := 1

CONFIG_PRINT_CR := 1 ; print CR when line end reached
CONFIG_SAFE_NAMENOTFOUND := 1
CONFIG_SCRTCH_ORDER := 2

; zero page: KIM-1 order, shifted by 3 to make room for the USR JMP vector that a
; ROM-style build needs (the KIM-1 RAM build keeps USR elsewhere).
;   $00-$09 GORESTART..GOGIVEAYF, $0A-$0C USR, $0D-$17 CHARAC..Z14,
;   $18-$1D Z15..LINNUM, $1E-$65 INPUTBUFFER (72 bytes, as KIM-1), $66- the rest
USR       := $000A
ZP_START1 = $00
ZP_START2 = $18
ZP_START3 = $0D
ZP_START4 = $66

; constants
STACK_TOP       := $FC
SPACE_FOR_GOSUB := $36
WIDTH           := 72
WIDTH2          := 56

; memory layout
RAMSTART2       := RAMSTART

; monitor functions (KAGURA BIOS jump table)
MONRDKEY        := BIOS_RDKEY
MONCOUT         := BIOS_CHROUT
