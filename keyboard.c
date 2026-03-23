#include "keyboard.h"
#include "io.h"
#include "isr.h"
#include "pic.h"

// Simple US Keyboard Map (incomplete, just basics)
unsigned char kbdus[128] =
{
    0,  27, '1', '2', '3', '4', '5', '6', '7', '8',	/* 9 */
  '9', '0', '-', '=', '\b',	/* Backspace */
  '\t',			/* Tab */
  'q', 'w', 'e', 'r',	/* 19 */
  't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',	/* Enter key */
    0,			/* 29   - Control */
  'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',	/* 39 */
 '\'', '`',   0,		/* Left shift */
 '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',   0,				/* Right shift */
  '*',
    0,	/* Alt */
  ' ',	/* Space bar */
    0,	/* Caps lock */
    0,	/* 59 - F1 key ... > */
    0,   0,   0,   0,   0,   0,   0,   0,
    0,	/* < ... F10 */
    0,	/* 69 - Num lock*/
    0,	/* Scroll Lock */
    0,	/* Home key */
    0,	/* Up Arrow */
    0,	/* Page Up */
  '-',
    0,	/* Left Arrow */
    0,
    0,	/* Right Arrow */
  '+',
    0,	/* 79 - End key*/
    0,	/* Down Arrow */
    0,	/* Page Down */
    0,	/* Insert Key */
    0,	/* Delete Key */
    0,   0,   0,
    0,	/* F11 Key */
    0,	/* F12 Key */
    0,	/* All other keys are undefined */
};

extern void terminal_putchar(char c); // From kernel.c

static int keyboard_printing_enabled = 0;

void keyboard_enable(void) {
    keyboard_printing_enabled = 1;
}

void keyboard_handler(registers_t *regs)
{
    (void)regs;
    
    // Read status register
    // uint8_t status = inb(0x64);
    // If status & 0x1, buffer full.
    
    uint8_t scancode = inb(0x60);
    
    // If top bit set, it's key release. Ignore for now.
    if (scancode & 0x80)
    {
        // Key release
    }
    else
    {
        // Key press
        if (scancode < 128) {
            char c = kbdus[scancode];
            if (c != 0 && keyboard_printing_enabled) {
                terminal_putchar(c);
            }
        }
    }
}

void keyboard_init(void)
{
    register_interrupt_handler(33, keyboard_handler); // IRQ1 = 32 + 1 = 33
    
    // Unmask IRQ1
    irq_clear_mask(1);
}
