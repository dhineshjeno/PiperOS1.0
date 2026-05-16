/* kernel.c */
#include <stdint.h>
#include <stddef.h>
#include "idt.h"
#include "gdt.h"
#include "pic.h"
#include "keyboard.h"

/* Hardware text mode color constants. */
enum vga_color {
    VGA_COLOR_BLACK = 0,
    VGA_COLOR_BLUE = 1,
    VGA_COLOR_GREEN = 2,
    VGA_COLOR_CYAN = 3,
    VGA_COLOR_RED = 4,
    VGA_COLOR_MAGENTA = 5,
    VGA_COLOR_BROWN = 6,
    VGA_COLOR_LIGHT_GREY = 7,
    VGA_COLOR_DARK_GREY = 8,
    VGA_COLOR_LIGHT_BLUE = 9,
    VGA_COLOR_LIGHT_GREEN = 10,
    VGA_COLOR_LIGHT_CYAN = 11,
    VGA_COLOR_LIGHT_RED = 12,
    VGA_COLOR_LIGHT_MAGENTA = 13,
    VGA_COLOR_LIGHT_BROWN = 14,
    VGA_COLOR_WHITE = 15,
};

static inline uint8_t vga_entry_color(enum vga_color fg, enum vga_color bg) 
{
    return fg | bg << 4;
}

static inline uint16_t vga_entry(unsigned char uc, uint8_t color) 
{
    return (uint16_t) uc | (uint16_t) color << 8;
}

size_t strlen(const char* str) 
{
    size_t len = 0;
    while (str[len])
        len++;
    return len;
}

static const size_t VGA_WIDTH = 80;
static const size_t VGA_HEIGHT = 25;

size_t terminal_row;
size_t terminal_column;
uint8_t terminal_color;
uint16_t* terminal_buffer;

void terminal_initialize(void) 
{
    terminal_row = 0;
    terminal_column = 0;
    terminal_color = vga_entry_color(VGA_COLOR_LIGHT_GREY, VGA_COLOR_BLACK);
    terminal_buffer = (uint16_t*) 0xB8000;
    for (size_t y = 0; y < VGA_HEIGHT; y++) {
        for (size_t x = 0; x < VGA_WIDTH; x++) {
            const size_t index = y * VGA_WIDTH + x;
            terminal_buffer[index] = vga_entry(' ', terminal_color);
        }
    }
}

void terminal_setcolor(uint8_t color) 
{
    terminal_color = color;
}

void terminal_putentryat(char c, uint8_t color, size_t x, size_t y) 
{
    const size_t index = y * VGA_WIDTH + x;
    terminal_buffer[index] = vga_entry(c, color);
}

void terminal_putchar(char c) 
{
    if (c == '\n') {
        terminal_column = 0;
        if (++terminal_row == VGA_HEIGHT)
            terminal_row = 0;
    } else if (c == '\b') {
        if (terminal_column > 0) {
            terminal_column--;
            terminal_putentryat(' ', terminal_color, terminal_column, terminal_row);
        }
    } else {
        terminal_putentryat(c, terminal_color, terminal_column, terminal_row);
        if (++terminal_column == VGA_WIDTH) {
            terminal_column = 0;
            if (++terminal_row == VGA_HEIGHT)
                terminal_row = 0;
        }
    }
}

void terminal_writestring(const char* data) 
{
    size_t datalen = strlen(data);
    for (size_t i = 0; i < datalen; i++)
        terminal_putchar(data[i]);
}

static inline void outb(uint16_t port, uint8_t val)
{
    asm volatile ( "outb %0, %1" : : "a"(val), "Nd"(port) );
}

void terminal_putentryat_string(const char* str, uint8_t color, size_t x, size_t y) {
    size_t len = strlen(str);
    for (size_t i = 0; i < len; i++) {
        terminal_putentryat(str[i], color, x + i, y);
    }
}

void disable_cursor(void)
{
    outb(0x3D4, 0x0A);
    outb(0x3D5, 0x20);
}

void sleep(unsigned int mseconds)
{
    // A VERY approximate delay loop since we don't have timer interrupts yet
    // Adjusted speed as requested
    volatile unsigned long long count = 0;
    unsigned long long target = mseconds * 333333; 
    while (count < target) count++;
}

void terminal_clear(void)
{
    for (size_t y = 0; y < VGA_HEIGHT; y++) {
        for (size_t x = 0; x < VGA_WIDTH; x++) {
            const size_t index = y * VGA_WIDTH + x;
            terminal_buffer[index] = vga_entry(' ', terminal_color);
        }
    }
    terminal_row = 0;
    terminal_column = 0;
}

void type_text_centered(const char* text, size_t row, uint8_t color, unsigned int delay_ms)
{
    size_t len = strlen(text);
    size_t start_col = (VGA_WIDTH - len) / 2;
    terminal_row = row;
    terminal_column = start_col;
    terminal_setcolor(color);

    for (size_t i = 0; i < len; i++) {
        terminal_putchar(text[i]);
        sleep(delay_ms);
    }
}

void kernel_main(void) 
{
    terminal_initialize();
    disable_cursor(); // Hide the distracting hardware cursor
    
    // Initialize Interrupts
    gdt_init();
    idt_init();
    pic_remap(0x20, 0x28); // Map IRQ0-7 to 32-39, IRQ8-15 to 40-47
    keyboard_init();
    
    // Enable Interrupts
    asm volatile("sti");

    // ── Clean Piper OS Boot Animation ─────────────────────────────────────
    uint8_t col_cyan  = vga_entry_color(VGA_COLOR_LIGHT_CYAN,  VGA_COLOR_BLACK);
    uint8_t col_white = vga_entry_color(VGA_COLOR_WHITE,        VGA_COLOR_BLACK);
    uint8_t col_green = vga_entry_color(VGA_COLOR_LIGHT_GREEN,  VGA_COLOR_BLACK);
    uint8_t col_grey  = vga_entry_color(VGA_COLOR_LIGHT_GREY,   VGA_COLOR_BLACK);

    terminal_clear();

    terminal_setcolor(col_cyan);
    terminal_writestring("+==============================================+\n");
    terminal_setcolor(col_white);
    terminal_writestring("|              PIPER OS v0.1                   |\n");
    terminal_setcolor(col_cyan);
    terminal_writestring("+==============================================+\n\n");

    terminal_setcolor(col_green);
    terminal_writestring("   _____ _                 \n");
    terminal_writestring("  |  __ (_)                \n");
    terminal_writestring("  | |__) | | ___ _ __ _ __ \n");
    terminal_writestring("  |  ___/ |/ _ \\ '__| '__|\n");
    terminal_writestring("  | |   | |  __/ |  | |   \n");
    terminal_writestring("  |_|   |_|\\___|_|  |_|   \n");
    terminal_writestring("     Operating System\n\n");

    struct { const char* label; } checks[] = {
        { "[BIOS] Checking pipes...         " },
        { "[CPU ] Initializing core flow... " },
        { "[MEM ] Pipe RAM detected         " },
        { "[KBD ] Keyboard pipes ready      " },
        { "[IRQ ] Interrupt lines active    " },
    };
    for (int i = 0; i < 5; i++) {
        terminal_setcolor(col_grey);
        terminal_writestring(checks[i].label);
        sleep(120);
        terminal_setcolor(col_green);
        terminal_writestring(" OK\n");
    }

    terminal_setcolor(col_cyan);
    terminal_writestring("\nBooting Kernel [");
    for (int i = 0; i < 30; i++) {
        terminal_setcolor(col_green);
        terminal_putchar('=');
        sleep(40);
    }
    terminal_setcolor(col_cyan);
    terminal_writestring("] 100%\n\n");

    terminal_setcolor(col_green);
    terminal_writestring("Piper OS Kernel Loaded Successfully!\n\n");
    // ── End of animation ──────────────────────────────────────────────────

    terminal_setcolor(col_green);
    terminal_writestring("> ");
    // Disable direct printing, shell will handle echo
    keyboard_disable();
    
    char cmdbuf[256];
    int cmdpos = 0;
    
    while(1) {
        // Draw cursor
        terminal_putentryat('_', vga_entry_color(VGA_COLOR_LIGHT_GREEN, VGA_COLOR_BLACK), terminal_column, terminal_row);
        
        char c = keyboard_get_char();
        if (c != 0) {
            // Remove cursor before echoing
            terminal_putentryat(' ', vga_entry_color(VGA_COLOR_LIGHT_GREEN, VGA_COLOR_BLACK), terminal_column, terminal_row);
            
            if (c == '\n') {
                terminal_putchar('\n');
                cmdbuf[cmdpos] = '\0';
                
                // Process command
                if (cmdpos > 0) {
                    if (cmdbuf[0] == 'h' && cmdbuf[1] == 'e' && cmdbuf[2] == 'l' && cmdbuf[3] == 'p' && cmdbuf[4] == '\0') {
                        terminal_writestring("Piper OS v0.1\n");
                        terminal_writestring("Commands: help, clear, echo\n");
                    } else if (cmdbuf[0] == 'c' && cmdbuf[1] == 'l' && cmdbuf[2] == 'e' && cmdbuf[3] == 'a' && cmdbuf[4] == 'r' && cmdbuf[5] == '\0') {
                        terminal_clear();
                    } else if (cmdbuf[0] == 'e' && cmdbuf[1] == 'c' && cmdbuf[2] == 'h' && cmdbuf[3] == 'o' && cmdbuf[4] == ' ') {
                        terminal_writestring(&cmdbuf[5]);
                        terminal_writestring("\n");
                    } else {
                        terminal_writestring("Command not found: ");
                        terminal_writestring(cmdbuf);
                        terminal_writestring("\n");
                    }
                }
                
                // Print prompt
                terminal_setcolor(vga_entry_color(VGA_COLOR_LIGHT_GREEN, VGA_COLOR_BLACK));
                terminal_writestring("> ");
                cmdpos = 0;
            } else if (c == '\b') {
                if (cmdpos > 0) {
                    cmdpos--;
                    terminal_putchar('\b');
                }
            } else {
                if (cmdpos < 255) {
                    cmdbuf[cmdpos++] = c;
                    terminal_putchar(c);
                }
            }
        } else {
            // Just small sleep so we don't hog CPU entirely
            // No sleep is okay, but cursor blinking needs timing if we want it.
            // Let's just do a tiny sleep
            sleep(1);
        }
    }
}
