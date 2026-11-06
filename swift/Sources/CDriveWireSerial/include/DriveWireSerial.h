#ifndef DRIVEWIRE_SERIAL_H
#define DRIVEWIRE_SERIAL_H
#include <stddef.h>
#include <stdint.h>
typedef struct dw_serial dw_serial;
/* UTF-8 port paths and errors. Reads time out after 100ms; zero means timeout. */
dw_serial *dw_serial_open(const char *path, int baud, int dtr, int rts, char *error, size_t capacity);
int dw_serial_read(dw_serial *port, uint8_t *buffer, int capacity, char *error, size_t error_capacity);
int dw_serial_write(dw_serial *port, const uint8_t *buffer, int count, char *error, size_t error_capacity);
void dw_serial_cancel(dw_serial *port);
void dw_serial_close(dw_serial *port);
/* Newline-separated UTF-8 paths, excluding the final NUL; -1 on failure. */
int dw_serial_ports(char *buffer, size_t capacity, char *error, size_t error_capacity);
#endif
