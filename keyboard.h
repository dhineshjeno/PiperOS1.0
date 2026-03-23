#ifndef KEYBOARD_H
#define KEYBOARD_H

#include "isr.h"

void keyboard_init(void);
void keyboard_handler(registers_t *regs);
void keyboard_enable(void);

#endif
