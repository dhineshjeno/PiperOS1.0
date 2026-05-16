#ifndef KEYBOARD_H
#define KEYBOARD_H

#include "isr.h"

void keyboard_init(void);
void keyboard_enable(void);
void keyboard_disable(void);
char keyboard_get_char(void);

#endif
