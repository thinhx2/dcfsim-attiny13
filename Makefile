#
#
#

AVRBIN=/Applications/Arduino.app/Contents/Resources/Java/hardware/tools/avr/bin

dcf77sim.elf: dcf77sim.asm
	cat tn13def.inc dcf77sim.asm | awk 'BEGIN{}/^.def/{print length($$2)" s/"$$2"/"$$4"/"}END{}' | sort -n -r | sed 's/. //' > dcf77sim.def
	sed -f dcf77sim.def dcf77sim.asm > dcf77sim.pre
	cat tn13def.inc dcf77sim.pre | sed 's/^.def.*//;s/.include.*//;s/.equ\(.*\)=\(.*\)/.equ \1, \2/;s/.cseg.*//;s/.device.*//;s/.org.*INT0addr.*/\.org 0x0002/;s/.org.*OVF0addr.*/\.org 0x0006/' > dcf77sim.s
	$(AVRBIN)/avr-as -mmcu=attiny13 -o dcf77sim.o dcf77sim.s
	$(AVRBIN)/avr-ld dcf77sim.o -o dcf77sim.elf
	$(AVRBIN)/avr-objcopy -j .text -j .data -O ihex dcf77sim.elf dcf77sim.hex

flash:
	$(AVRBIN)/avrdude -c usbtiny -C $(AVRBIN)/../etc/avrdude.conf -p t13 -U flash:w:dcf77sim.hex 

# ext clock
fuse:
	$(AVRBIN)/avrdude -c usbtiny -C $(AVRBIN)/../etc/avrdude.conf -p t13  -U lfuse:w:0x68:m -U hfuse:w:0xff:m

clean:
	rm -rf *.o *.elf *.hex *.def *.pre *.s
