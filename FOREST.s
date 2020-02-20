;*************************************************************
;* FILE: Forest.s
;*************************************************************
;* Description:
;*  Simple music player for the ORIC 1 & Oric Atmos.
;*  Based on a Z80 program I found with the Virtual Aquarius emulator (I think)
;*  Uses VIA timer to trigger the interrupt,
;*  other machines may use the vertical blank interrupt.
;*  Designed for the General Instruments AY sound chip but will work
;*  with any sound chip with an internal address register and a data register.
;*  This software is in the public domain.
;*
;* Song Data Format:
;*	;wait, number of registers to change,
;*	;	register number, new value
;*	;	register number, new value
;*	;	etc.
;*	; ends when number of registers to change is 0.
;*
;* Author: James Diffendaffer
;* Date: May 29, 2009
;* Version:
;************************************************************* 

; set build conditions here
;#define USE_C02	1	; define to use 65C02 instructions
#define USENTSC		1	; define to use NTSC VIA Timer settings
#define ORICAY		1	; Use Oric VIA mapped AY chip, otherwise memory mapped AY

;*
#ifndef ORICAY
#define AYBase	$0000		; Put base address of memory mapped AY Chip here
#endif

#ifndef	USENTSC
#define	VBLVIA	$4E00		; VIA Timer Latch, settings matching PAL 50Hz
#else
#define	VBLVIA	$4100		; VIA Timer Latch, settings matching NTSC 60Hz
#endif

#define	IRQloc	$024A		; IRQ handler address

; VIA register definitions
#define	VIA_T1C	$0304		; Read/Write Counter Low-High T1
#define	VIA_T1L	$0306		; Read/Write Latch Low-High T1
#define	VIA_PCR	$030C		; Peripheral Control Register
#define	VIAIORA	$030F		; Printer/Sound/Joystick (No Handshake)


	.zero			; page zero variables
	*=	$007C		; start at $7C, right after OSDK reserved space
song	.dsb	2,$00		; page zero song pointer
cmds	.dsb	2,$00		; page zero command table pointer
temp	.dsb	1,$00		; temporary storage (for the Y register)
	.text			; start of code segment
	*=	$0600		; start address of code
START				; just so we have the start address in the list file
_main
;==================
; playsong,
;	play a song located at songstart
;	based on Z80 Aquarius version by James the Animal Tamer
;	ORIC 6502 XA source port by James Diffendaffer
; NOTE- uses timer interrupt rather than TOF interrupt despite code comments

playsong
	; save registers
	pha
#ifdef	USE_C02
	phx			;65c02
	phy			;65c02
#else
	txa
	pha
	tya
	pha
#endif	

;save VIA settings?


; clear the interrupt counter
	lda	#0		; clear the interrupt handler counter
	sta	_VblCounter

	; set the start address of the song
	lda	#<songstart
	sta	song
	lda	#>songstart
	sta	song+1

	; set the start address of the commandtable
	lda	#<commandtable
	sta	cmds
	lda	#>commandtable
	sta	cmds+1

; set up a VIA timer for our interrupt
	sei			; disable interrupts

	lda	VIA_T1L		; get contents of VIA_T1 and save for exit
	sta	VIASAVE
	lda	VIA_T1L+1
	sta	VIASAVE+1

	lda	#<VBLVIA	; Set our own VIA_T1 value for 50Hz or 60Hz
	sta	VIA_T1L
	lda	#>VBLVIA
	sta	VIA_T1L+1

	;add our interrupt handler in place of rti on 6502 mem page 2
	lda	#$4C		; JMP instruction
	sta	IRQloc
	lda	#<_VBLIrq	; address of our interrupt handler
	sta	IRQloc+1
	lda	#>_VBLIrq
	sta	IRQloc+2
	cli			; enable interrupts

	;start of player
playline
	ldy	#1			; offset from song pointer, Y must be used for this addressing mode
	lda	(song),y	; get number of registers to modify

	bmi	docomnd	; negative numbers are commands
	;beq	playsongend	; check for end of song

#ifdef	USE_C02
	lda	(song)		; get wait in A (65c02)
#else
	dey
	lda	(song),y	; get wait in A
	iny
#endif
	tax			; move the counter to X
	jsr	waittof		; wait top of frame, A times

	lda	(song),y	; get number of registers to modify in A
	tax			; put it in X
	iny			; next byte in song

_reglop
	lda	(song),y	; get the register number to modify
;6502 ORIC AY Control using the VIA 6522 makes this slower than memory mapped AY chip
#ifdef	ORICAY
	sta	VIAIORA		; set the AY data register number
	lda	#$FF		; $FF = VIAIORA holds a register number
	sta	VIA_PCR		; Set the VIA 6522 control line Register(PCR)
	lda	#$DD		; $DD = VIAIORA is inactive 
	sta	VIA_PCR		; Set the VIA 6522 control line Register(PCR)
#else
	sta	AYBase+1	; set the AY data register number
#endif
	iny			; point to next byte in song
	lda	(song),y	; get the Value for the AY register
#ifdef	ORICAY
	sta	VIAIORA		; load the data register value
	lda	#$FD		; $FD = VIAIORA holds data for a preset register 
	sta	VIA_PCR		; Set the VIA 6522 control line Register(PCR)
	lda	#$DD		; $DD = VIAIORA is inactive
	sta	VIA_PCR		; Set the VIA 6522 control line Register(PCR)
#else
	sta	AYBase		; load the data register value
#endif
	iny			; point to next byte in song
	dex			; decrement the register count
	bne	_reglop		; keep looping if not done setting registers


; update the pointer (16 bit song pointer + 8 bit addition)
; (songLSB + y, songMSB + carry)
	clc			; clear the carry for out 16 bit addition
	tya			; put pointer offset in A
	adc	song		; add low byte (LSB)
	sta	song		; update low byte
	lda	#0		; clear A
	adc	song+1		; add carry to high byte (MSB)
	sta	song+1		; update the song pointer
#ifdef	USE_C02
	bra	playline	; continue playing (65c02)
#else
	;clc
	bcc	playline	; continue playing
#endif

;======================
docomnd
;	beq	playsongend
	sty	temp	; save Y

	; self modifying code
	; register A contains the command number + 128
	; adjust the command pointer to get command table offset
;	and	#%01111111	; mask off top bit.  Not required due to ROL
	clc				; CLC for the ROL
					; ROL moves top bit to carry and previous carry goes to bottom bit
	rol				; bit shift = multiply by 2 (addresses are 2 bytes in size)

	; get command address from command pointer table (self modifying code)
	tay				; move the command table offset to Y
	lda	(cmds),y	; load the 1st byte of the command pointer into A
	sta	ijmp+1		; modify the 1st byte of the address in the jmp
	iny				; adjust offset for next byte
	lda	(cmds),y	; load the 2nd byte of the command pointer into A
	sta	ijmp+2		; modify the 2nd byte of the address in the jmp
	
	ldy	temp		; restore Y
ijmp	jmp	playsongend	; playsong end replaced with current command address


;===============================
	
playsongend
	;stop sound?
	sei			; disable interrupts

	;restore previous VIA timer
	lda	VIASAVE
	sta	VIA_T1L
	lda	VIASAVE+1
	sta	VIA_T1L+1

	; remove our interrupt handler
	lda	#$40		; RTI instruction
	sta	IRQloc
	cli			; enable interrupts

	; restore registers we saved
#ifdef	USE_C02
	ply			; 65c02
	plx			; 65c02
#else
	pla
	tay
	pla
	tax
#endif
	pla

	rts			; return 


;==================
; waittof,
;	wait top of frame, a times
;	preserve registers
waittof
loop_wait
	lda	_VblCounter
	beq	loop_wait
	lda	#0
	sta	_VblCounter
	dex			; decrement the counter
	bne	loop_wait
	rts


;==================
; our interrupt handler
_VBLIrq
	bit	VIA_T1C
	inc	_VblCounter
	rti


codeend
	
;	.bss			; start of the bss data segment
;==================
; variables we change
_VblCounter	.byt	0	; TOF flag variable
VIASAVE	.byt	00,00
;	.data			; start of data segment

;===============================	
commandtable
	.word	playsongend		; 0 end of song
	.word	playsongend		; just in case
;==================
songstart
	; rem  song
	; rem wait, number of registers to change,
	;	register number, new value
	;	register number, new value
	;	etc.
	; ends when number of registers to change is 0.
	.byt	1,4,8,0,9,0,10,0,7,56
	;-- snip
	.byt	1,3,0,221,1,1,8,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,8,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	 14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	29,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	29,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,236,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,89,1,2,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	29,2,8,0,9,0
	.byt	1,3,0,246,1,2,8,15
	.byt	29,1,8,0
	.byt	1,3,0,236,1,5,8,15
	.byt	29,1,8,0
	.byt	1,3,0,221,1,1,8,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,8,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	13,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	29,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,112,3,4,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,246,3,2,9,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,8,0
	.byt	1,7,0,221,1,1,8,15,9,0,2,151,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,169,1,1,8,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,123,3,1,9,15
	.byt	29,1,8,0
	.byt	1,7,0,221,1,1,8,15,9,0,2,244,3,3,9,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	29,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,112,3,4,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,246,3,2,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,8,0
	.byt	1,7,0,89,1,2,8,15,9,0,2,236,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,236,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	29,2,8,0,9,0
	.byt	1,3,0,221,1,1,8,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,8,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	28,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	13,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,123,3,1,9,15
	.byt	28,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	29,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,236,1,5,8,15,2,89,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,236,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,112,3,4,9,15
	.byt	29,2,8,0,9,0
	.byt	30,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,4,9,0,2,125,3,2,9,15
	.byt	15,6,0,251,1,4,8,15,4,62,5,1,10,15
	.byt	14,1,10,0
	.byt	1,4,9,0,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,123,1,1,8,15,9,0,2,187,3,3,9,15
	.byt	14,1,8,0
	.byt	1,3,0,169,1,1,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,62,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,9,0
	.byt	1,6,2,236,3,5,9,15,4,123,5,1,10,15
	.byt	14,2,8,0,10,0
	.byt	1,3,0,169,1,1,8,15
	.byt	13,2,8,0,9,0
	.byt	1,9,0,179,1,4,8,15,2,246,3,2,9,15,4,221,5,1
	.byt	10,15
	.byt	13,1,10,0
	.byt	1,3,4,250,5,1,10,15
	.byt	13,3,8,0,9,0,10,0
	.byt	1,6,0,112,1,4,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,246,3,2,9,15
	.byt	13,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	28,2,8,0,9,0
	.byt	1,3,0,123,1,1,8,15
	.byt	13,1,8,0
	.byt	1,3,0,62,1,1,8,15
	.byt	13,1,8,0
	.byt	1,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	13,1,8,0
	.byt	1,4,9,0,2,125,3,2,9,15
	.byt	14,6,0,251,1,4,8,15,4,62,5,1,10,15
	.byt	13,2,9,0,10,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,221,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,203,1,2,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,236,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,89,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	30,2,8,0,9,0
	.byt	32,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,4,9,0,2,125,3,2,9,15
	.byt	15,6,0,251,1,4,8,15,4,62,5,1,10,15
	.byt	14,1,10,0
	.byt	1,4,9,0,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,123,1,1,8,15,9,0,2,187,3,3,9,15
	.byt	14,1,8,0
	.byt	1,3,0,169,1,1,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,62,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,9,0
	.byt	1,6,2,236,3,5,9,15,4,123,5,1,10,15
	.byt	14,2,8,0,10,0
	.byt	1,3,0,169,1,1,8,15
	.byt	13,2,8,0,9,0
	.byt	1,9,0,179,1,4,8,15,2,246,3,2,9,15,4,221,5,1
	.byt	10,15
	.byt	13,1,10,0
	.byt	1,3,4,250,5,1,10,15
	.byt	13,3,8,0,9,0,10,0
	.byt	1,6,0,112,1,4,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,246,3,2,9,15
	.byt	13,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	29,2,8,0,9,0
	.byt	1,3,0,123,1,1,8,15
	.byt	13,1,8,0
	.byt	1,3,0,62,1,1,8,15
	.byt	13,1,8,0
	.byt	1,6,0,83,1,3,8,15,2,101,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,56,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,9,0
	.byt	1,6,2,251,3,4,9,15,4,62,5,1,10,15
	.byt	13,2,8,0,10,0
	.byt	1,3,0,101,1,1,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,123,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,221,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,236,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,89,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	30,2,8,0,9,0
	.byt	32,3,0,221,1,1,8,15
	.byt	14,1,8,0
	.byt	1,3,0,250,1,1,8,15
	.byt	14,1,8,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,1,9,0
	.byt	1,7,8,0,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	28,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,112,3,4,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,123,3,1,9,15
	.byt	28,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	13,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	14,2,8,0,9,0
	.byt	1,6,0,203,1,2,8,15,2,123,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,251,1,4,8,15,2,62,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,101,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,83,1,3,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,187,1,3,8,15,2,221,3,1,9,15
	.byt	28,2,8,0,9,0
	.byt	1,6,0,244,1,3,8,15,2,221,3,1,9,15
	.byt	13,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,112,1,4,8,15,2,56,3,2,9,15
	.byt	13,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,56,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,125,3,2,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,236,1,5,8,15,2,89,3,2,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,246,1,2,8,15,2,123,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,169,3,1,9,15
	.byt	13,2,8,0,9,0
	.byt	1,6,0,151,1,5,8,15,2,221,3,1,9,15
	.byt	14,1,9,0
	.byt	1,3,2,250,3,1,9,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,236,3,5,9,15
	.byt	14,1,8,0
	.byt	1,3,0,125,1,2,8,15
	.byt	14,1,8,0
	.byt	1,7,0,56,1,2,8,15,9,0,2,112,3,4,9,15
	.byt	30,2,8,0,9,0
	;--	unsnip
	.byt	1,3,8,0,9,0,10,0
;	.byt	0,0
	.byt	128,128
;===	end	of	song

dataend				; so we have the end of the data in the list file
	
	;.end
