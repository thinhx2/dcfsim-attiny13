;ATTiny11 @ 4.194304 MHz external crystal

;Version 2008-06-16

;Pinout:
;  PB0 = DCF77 signal output
;  PB1 = UART Rx input (9600 Baud, from PC)
;  PB2 = Status LED output (active low)
;  PB3 = XTAL 1
;  PB4 = XTAL 2

;registers for DCF77 telegram
;         MSB                                       LSB
;       +-----+-----+-----+-----+-----+-----+-----+-----+   LS = leap second
;dcf1 = | m20 | m10 | m8  | m4  | m2  | m1  |  S  | LS  |   S = start bit (1)
;       +-----+-----+-----+-----+-----+-----+-----+-----+   m = minutes
;dcf2 = | h20 | h10 | h8  | h4  | h2  | h1  | MnP | m40 |   MnP = minutes parity
;       +-----+-----+-----+-----+-----+-----+-----+-----+   h = hours
;dcf3 = | WD1 | D20 | D10 | D8  | D4  | D2  | D1  | HrP |   hours parity
;       +-----+-----+-----+-----+-----+-----+-----+-----+   D = day
;dcf4 = | Y1  | M10 | M8  | M4  | M2  | M1  | WD4 | WD2 |   WD = weekday
;       +-----+-----+-----+-----+-----+-----+-----+-----+   M = month
;dcf5 = | DaP | Y80 | Y40 | Y20 | Y10 | Y8  | Y4  | Y2  |   Y = year
;       +-----+-----+-----+-----+-----+-----+-----+-----+   DaP = date parity

;.equ	BITLEN = 55 ;RS232 bit length in Timer ticks
.equ	BITLEN = 23 ;RS232 bit length in Timer ticks

;R0-R15: UART buffer / DCF77 bitstream
.def	temp = R16
.def	temp2 = R17
.def	bit_cnt = R18
.def	curmin = R18
.def	byte = R19
.def	bufpos = R20
.def	minute = R21
.def	hour = R22
.def	day = R23
.def	month = R24
.def	year = R25
.def	wkday = R26
.def	timediv = R27
.def	dcftime = R28
.def	dcfpos = R29
;R30 = ZL used for "RAM" (R0..R15) access
.def	startbit = R31

.include "../include/tn11def.inc"

;===============================================================================

.cseg
.org 0x000
	rjmp	reset
.org INT0addr
	rjmp	uart_start
.org OVF0addr
	cpi	wkday, 0xFF
	breq	uart_bit
	rjmp	dcf77_tick

;===============================================================================

dcf77_tick:
	;timer 0 overflow (256 Hz): update DCF77 output
	
	;decrement DCF77 pulse length couter, end pulse when it reaches 0
	cpi	dcftime, 0
	breq	dcf77_div
	dec	dcftime
	brne	dcf77_div
	cbi	PORTB, 0
	
dcf77_div:
	;divide interrupt frequency to 1 Hz
	dec	timediv
	brne	dcf77_end
	
	;increment position in DCF77 telegram and return
	mov	temp, dcfpos
	inc	dcfpos
	cpi	dcfpos, 60
;	brlo	PC+2
	brlo	tag1

	ldi	dcfpos, 0

	;check if bit position is within bitstream or end-of-telegram
tag1:
	cpi	temp, 1
	brne	not_start
	cbi	PORTB, 2	; tune on LED
	
not_start:
	cpi	temp, 18
	brlo	dcf77_zero
	breq	dcf77_one ;GMT+1
	cpi	temp, 59
	brne	next_sec

	sbi	PORTB, 2	; tune off LED
	rcall	minute_inc	; calculate next minute
	rjmp	dcf77_end

next_sec:
	;calculate byte address (ZL) and bit mask (temp2) for bitstream
	subi	temp, 19
	mov	ZL, temp
	lsr	ZL
	lsr	ZL
	lsr	ZL
	ldi	temp2, 0x01
	andi	temp, 0x07
	breq	dcf77_bit
dcf77_bitmask:
	lsl	temp2
	dec	temp
	brne	dcf77_bitmask
	
dcf77_bit:
	;load bit from DCF77 bitstream
	ld	temp, Z
	and	temp, temp2
	brne	dcf77_one
	
dcf77_zero:
	;start sending a zero bit (100ms pulse)
	sbi	PORTB, 0
	ldi	dcftime, 25 ;25/256s = ~100ms
	rjmp	dcf77_end

dcf77_one:
	;start sending a one bit (200ms pulse)
	sbi	PORTB, 0
	ldi	dcftime, 51 ;51/256s = ~200ms
	rjmp	dcf77_end
	
dcf77_end:
	reti

;===============================================================================

uart_start:
	;external interrupt on falling edge, indicating start of a byte
	
	;load timer with 1/2 bit length and enable it's overflow interrupt
;	ldi	temp, 256-(BITLEN/2)
	ldi	temp, 256-2
	out	TCNT0, temp
	ldi	temp, 1<<TOIE0
	out	TIFR0, temp ;clear overflow flag
	out	TIMSK0, temp ;enable interrupt
	ldi	temp, 0x01 ; start timer
	out	TCCR0B, temp

	;disable external interrupt
	clr	bit_cnt
	out	GIMSK, bit_cnt
	
	reti

;-------------------------------------------------------------------------------

uart_bit:
	;Timer0 overflow: receive one bit from the UART input

	ldi	temp, 0x00 ; stop timer
	out	TCCR0B, temp
	ldi	temp, 1<<TOIE0
	out	TIFR0, temp ;clear overflow flag

	;store bit
	inc	bit_cnt
	sec
	sbis	PINB, 1
	clc
	ror	byte
	
	;check for end-of-transmission and check start- and stop-bits
	in	temp, SREG
	cpi	bit_cnt, 1 ;start-bit
	brne	uart_startbit_end
	lsl	byte ;move start bit from 'byte' to 'startbit'
	rol	startbit
uart_startbit_end:
	cpi	bit_cnt, 10 ;stop-bit
	breq	uart_get_byte

	;reload timer
	out	SREG, temp
	ldi	temp, 256-BITLEN-1
	out	TCNT0, temp
	ldi	temp, 1<<TOIE0
	out	TIMSK0, temp ;enable interrupt
	ldi	temp, 0x01 ; start timer
	out	TCCR0B, temp
	reti

uart_get_byte:
	out	SREG, temp
	rol	byte ;remove stop bit from byte buffer
	brcc	uart_err_stop ;check stop-bit
	sbrc	startbit, 0 ;check start-bit
	rjmp	uart_err_start

	;store byte
	cpi	byte, 0x04 ;<Ctrl> + D
	breq	uart_complete
	cpi	byte, 0x0a ;LF
	breq	uart_complete
	cpi	byte, 0x0d ;CR
	breq	uart_complete
	cpi	bufpos, 16
	brsh	uart_err_ovf
	mov	ZL, bufpos
	st	Z, byte
	inc	bufpos
	rjmp	uart_restart

uart_err_bound:
	rcall	flash_led ;4x flash: time or date is not within boundaries
uart_err_str:
	rcall	flash_led ;3x flash: invalid string (e.g. letter instead of number)
uart_err_num:
	rcall	flash_led ;2x flash: wrong string length
uart_err_ovf:
	rcall	flash_led ;1x flash: buffer overflow

uart_err_start:
uart_err_stop:
uart_restart:
	;re-enable external interrupt
	ldi	temp, 1<<INTF0
	out	GIFR, temp
	ldi	temp, 1<<INT0
	out	GIMSK, temp
	
	;disable Timer0 overflow interrupt
	clr	temp
	out	TIMSK0, temp
	
	;reset wkday register to 0xFF
	ldi	wkday, 0xFF

uart_bit_end:
	reti

;--------------------

uart_complete:
	;16 characters received, check if they contain a correct string
	cpi	bufpos, 16
	ldi	bufpos, 0
	brne	uart_err_num
	ldi	ZL, 0
	clr	temp2
	rcall	check_digit ;year
	rcall	check_digit
	ldi	byte, '-'
	rcall	check_char
	rcall	check_digit ;month
	rcall	check_digit
	ldi	byte, '-'
	rcall	check_char
	rcall	check_digit ;day
	rcall	check_digit
	ldi	byte, '/'
	rcall	check_char
	rcall	check_digit ;weekday
	ldi	byte, ' '
	rcall	check_char
	rcall	check_digit ;hour
	rcall	check_digit
	ldi	byte, ':'
	rcall	check_char
	rcall	check_digit ;minute
	rcall	check_digit
	cpi	temp2, 0
	brne	uart_err_str
	
	;received a valid date/time information string
	ldi	ZL, 0
	rcall	ascii2bcd ;year
	mov	year, temp
	ldi	ZL, 3
	rcall	ascii2bcd ;month
	mov	month, temp
	cpi	month, 0x20
	brsh	uart_err_bound
	ldi	ZL, 6
	rcall	ascii2bcd ;day
	mov	day, temp
	cpi	day, 0x40
	brsh	uart_err_bound
	ldi	ZL, 9
	ld	wkday, Z
	andi	wkday, 0x0F
	cpi	wkday, 0x08
	brsh	uart_err_bound
	ldi	ZL, 11
	rcall	ascii2bcd ;hour
	mov	hour, temp
	cpi	hour, 0x40
	brsh	uart_err_bound
	ldi	ZL, 14
	rcall	ascii2bcd ;minute
	mov	minute, temp
	mov	curmin, temp
	cpi	minute, 0x80
;	brlo	PC+2
	brlo	tag2
	rjmp	uart_err_bound
	
tag2:
	;all checks passed, calculate DCF77 bitstream
	lsl	month
	lsl	month
	lsl	month
	lsr	year
	ror	month
	lsl	day
	lsl	day
	lsr	wkday
	ror	day
	or	month, wkday
	ldi	temp2, 0
	mov	temp, year
	rcall	parity
	mov	temp, month
	rcall	parity
	mov	temp, day
	rcall	parity
	sbrc	temp2, 0
	ori	year, 0x80 ;Date Parity Bit
	
	ldi	temp2, 0
	mov	temp, hour
	rcall	parity
	sbrc	temp2, 0
	ori	day, 0x01 ;Hour Parity Bit
	
	lsl	hour
	ldi	temp2, 0
	mov	temp, minute
	rcall	parity
	sbrc	temp2, 0
	ori	hour, 0x01 ;Minute Parity Bit
	lsl	minute
	lsl	minute
	rol	hour
	ori	minute, 0x02 ;Start Bit
	
	mov	R0, minute
	mov	R1, hour
	mov	R2, day
	mov	R3, month
	mov	R4, year
	
	;change timer overflow frequency to 256 Hz and turn on status LED
;	ldi	temp, 0x03 ;Clk/64
	ldi	temp, 0x02 ;Clk/8
	out	TCCR0B, temp
	ldi	temp, 0
	out	TCNT0, temp
	cbi	PORTB, 2 ;LED on
	rjmp	uart_bit_end
	
;-------------------------------------------------------------------------------

check_digit:
	;check if buffer byte is numeric (ASCII 0x30 to 0x39)
	ld	temp, Z
	inc	ZL
	cpi	temp, 0x30
	brlo	check_fail
	cpi	temp, 0x3A
	brsh	check_fail
	ret
	
check_char:
	;check if buffer matches a specific char
	ld	temp, Z
	inc	ZL
	cp	temp, byte
	brne	check_fail
	ret
	
check_fail:
	;check failed, set temp2 != 0
	ldi	temp2, 1
	ret
	
;--------------------

ascii2bcd:
	;convert 2 ASCII chars to a packed BCD value
	ld	temp2, Z
	inc	ZL
	ld	temp, Z
	swap	temp2
	andi	temp2, 0xF0
	andi	temp, 0x0F
	or	temp, temp2
	ret
	
;--------------------

parity:
	;calculate parity of 'temp' and add to 'temp2'
	sbrc	temp, 0
	inc	temp2
	lsr	temp
	brne	parity
	ret
	
;--------------------

flash_led:
	;flash LED once
	cbi	PORTB, 2 ;LED on
	ldi	temp, 3
	clr	temp2
	clr	byte
flash_led_1:
	dec	byte
	brne	flash_led_1
	dec	temp2
	brne	flash_led_1
	dec	temp
	brne	flash_led_1
	sbi	PORTB, 2 ;LED off
	ldi	temp, 3
flash_led_2:
	dec	byte
	brne	flash_led_2
	dec	temp2
	brne	flash_led_2
	dec	temp
	brne	flash_led_2
	ret

; only 0 to 9
minute_inc:
	inc	curmin
	mov	temp, curmin
	andi	temp, 0x0f
	cpi	temp, 10
	brne	minc1
	mov	temp, curmin
	andi	temp, 0xf0
	mov	curmin, temp
	
minc1:
	mov	hour, R1
	mov	minute, curmin
	lsr	hour
	lsr	hour
	lsl	hour
	ldi	temp2, 0
	mov	temp, minute
	rcall	parity
	sbrc	temp2, 0
	ori	hour, 0x01 ;Minute Parity Bit
	lsl	minute
	lsl	minute
	rol	hour
	ori	minute, 0x02 ;Start Bit
	mov	R0, minute
	mov	R1, hour
	ret
	
;===============================================================================

reset:
	ldi	temp, 0x00
	out	WDTCR, temp

	;set PORTB
	ldi	temp, 0x05
	out	DDRB, temp
	ldi	temp, 0x06
	out	PORTB, temp
	
	rcall	flash_led
	
	;init Timer 0
;	ldi	temp, 0x02 ;Clk/8
	ldi	temp, 0x00 ;Clk
	out	TCCR0B, temp
	ldi	temp, 1<<TOIE0
	out	TIMSK0, temp
	
	;enable external interrupt on falling edge
	ldi	temp, 1<<INT0
	out	GIMSK, temp
	ldi	temp, 1<<ISC01
	out	MCUCR, temp
	
	;init registers
	ldi	bit_cnt, 0
	ldi	bufpos, 0
	ldi	timediv, 0
	ldi	dcfpos, 0
	ldi	dcftime, 0
	ldi	wkday, 0xFF ;no valid date/time information yet
	
	;enable interrupts
	sei
	
;-------------------------------------------------------------------------------
	
loop:
	rjmp	loop
