#include "DriveWireSerial.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <wchar.h>
struct dw_serial { HANDLE handle; DWORD write_millis_per_byte; };
static void problem(char *out, size_t cap, const char *operation) {
    snprintf(out, cap, "%s: Windows error %lu", operation, (unsigned long)GetLastError());
}
dw_serial *dw_serial_open(const char *path, int baud, int dtr, int rts, char *error, size_t cap) {
    if (baud<300 || baud>1000000) { snprintf(error,cap,"Invalid serial baud rate");return NULL; }
    wchar_t name[1024];
    char qualified[1024];
    if (!strncmp(path,"\\\\.\\",4)) snprintf(qualified,sizeof(qualified),"%s",path);
    else snprintf(qualified,sizeof(qualified),"\\\\.\\%s",path);
    if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,qualified,-1,name,1024)) { problem(error,cap,"Port name");return NULL; }
    HANDLE handle=CreateFileW(name,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
    if (handle==INVALID_HANDLE_VALUE) { problem(error,cap,"Open serial port");return NULL; }
    DCB settings={0}; settings.DCBlength=sizeof(settings);
    if (!GetCommState(handle,&settings)) { problem(error,cap,"Get serial settings");CloseHandle(handle);return NULL; }
    settings.BaudRate=(DWORD)baud;settings.ByteSize=8;settings.Parity=NOPARITY;settings.StopBits=ONESTOPBIT;
    settings.fBinary=TRUE;settings.fParity=FALSE;settings.fOutxCtsFlow=FALSE;settings.fOutxDsrFlow=FALSE;
    settings.fDtrControl=dtr?DTR_CONTROL_ENABLE:DTR_CONTROL_DISABLE;
    settings.fRtsControl=rts?RTS_CONTROL_ENABLE:RTS_CONTROL_DISABLE;
    settings.fDsrSensitivity=FALSE;settings.fOutX=FALSE;settings.fInX=FALSE;
    settings.fErrorChar=FALSE;settings.fNull=FALSE;settings.fAbortOnError=FALSE;settings.fTXContinueOnXoff=TRUE;
    /* Allow a complete response to clock out even at slower baud rates. */
    DWORD per_byte=(DWORD)((10000+baud-1)/baud);
    COMMTIMEOUTS timeouts={MAXDWORD,MAXDWORD,100,per_byte,2000};
    if (!SetCommState(handle,&settings)||!SetCommTimeouts(handle,&timeouts)||!PurgeComm(handle,PURGE_RXCLEAR|PURGE_TXCLEAR)) {
        problem(error,cap,"Configure serial port");CloseHandle(handle);return NULL;
    }
    dw_serial *port=malloc(sizeof(*port));
    if (!port) { snprintf(error,cap,"Out of memory");CloseHandle(handle);return NULL; }
    port->handle=handle;port->write_millis_per_byte=per_byte;return port;
}
static int transfer(dw_serial *port, void *buffer, int count, int writing, char *error, size_t cap) {
    OVERLAPPED operation={0}; operation.hEvent=CreateEventW(NULL,TRUE,FALSE,NULL);
    if (!operation.hEvent) { problem(error,cap,"Create serial event");return -1; }
    DWORD transferred=0;
    BOOL ok=writing?WriteFile(port->handle,buffer,(DWORD)count,&transferred,&operation):ReadFile(port->handle,buffer,(DWORD)count,&transferred,&operation);
    if (!ok && GetLastError()==ERROR_IO_PENDING) {
        uint64_t deadline=writing ? 2100+(uint64_t)count*port->write_millis_per_byte : 200;
        DWORD wait=WaitForSingleObject(operation.hEvent,deadline>=MAXDWORD?MAXDWORD-1:(DWORD)deadline);
        if (wait==WAIT_TIMEOUT) {
            CancelIoEx(port->handle,&operation);
            /* Drain completion before releasing the OVERLAPPED stack/event. */
            GetOverlappedResult(port->handle,&operation,&transferred,TRUE);
            CloseHandle(operation.hEvent);
            if (!writing) return 0;
            snprintf(error,cap,"Serial write timed out");return -1;
        }
        ok=GetOverlappedResult(port->handle,&operation,&transferred,TRUE);
    }
    if (!ok) { problem(error,cap,writing?"Write serial port":"Read serial port");CloseHandle(operation.hEvent);return -1; }
    CloseHandle(operation.hEvent);return (int)transferred;
}
int dw_serial_read(dw_serial *port,uint8_t *data,int count,char *error,size_t cap) { return transfer(port,data,count,0,error,cap); }
int dw_serial_write(dw_serial *port,const uint8_t *data,int count,char *error,size_t cap) { return transfer(port,(void *)data,count,1,error,cap); }
void dw_serial_cancel(dw_serial *port) { CancelIoEx(port->handle,NULL); }
void dw_serial_close(dw_serial *port) { CloseHandle(port->handle);free(port); }
int dw_serial_ports(char *out,size_t cap,char *error,size_t error_cap) {
    wchar_t *names=calloc(65536,sizeof(wchar_t));size_t used=0;
    if (!names) { snprintf(error,error_cap,"Out of memory");return -1; }
    if (!QueryDosDeviceW(NULL,names,65536)) { problem(error,error_cap,"List serial ports");free(names);return -1; }
    for (wchar_t *name=names;*name;name+=wcslen(name)+1) {
        if (wcsncmp(name,L"COM",3)||name[3]<L'0'||name[3]>L'9') continue;
        wchar_t *tail=name+3;while (*tail>=L'0'&&*tail<=L'9') ++tail;if (*tail) continue;
        char path[64];int length=WideCharToMultiByte(CP_UTF8,0,name,-1,path,sizeof(path),NULL,NULL);
        if (length>0 && used+(size_t)length<cap) { memcpy(out+used,path,(size_t)length-1);used+=(size_t)length-1;out[used++]='\n'; }
    }
    free(names);out[used]=0;return (int)used;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <IOKit/serial/ioss.h>
#endif
struct dw_serial { int fd; struct termios previous; };
static void problem(char *out,size_t cap,const char *operation) { snprintf(out,cap,"%s: %s",operation,strerror(errno)); }
static speed_t speed(int baud) {
    switch (baud) {
    case 300:return B300;case 600:return B600;case 1200:return B1200;case 2400:return B2400;
    case 4800:return B4800;case 9600:return B9600;case 19200:return B19200;case 38400:return B38400;
    case 57600:return B57600;case 115200:return B115200;case 230400:return B230400;
#ifdef B460800
    case 460800:return B460800;
#endif
#ifdef B921600
    case 921600:return B921600;
#endif
    default:return 0;
    }
}
dw_serial *dw_serial_open(const char *path,int baud,int dtr,int rts,char *error,size_t cap) {
    if (baud<300 || baud>1000000) { snprintf(error,cap,"Invalid serial baud rate");return NULL; }
    int fd=open(path,O_RDWR|O_NOCTTY|O_NONBLOCK);
    if (fd<0) { problem(error,cap,"Open serial port");return NULL; }
    struct termios previous,settings;
    if (tcgetattr(fd,&previous)<0) { problem(error,cap,"Read serial settings");close(fd);return NULL; }
    settings=previous;cfmakeraw(&settings);
    settings.c_iflag &= ~(IXON|IXOFF|IXANY);
    settings.c_cflag=(settings.c_cflag&~(CSIZE|PARENB|CSTOPB))|CS8|CLOCAL|CREAD;
#ifdef CRTSCTS
    settings.c_cflag &= ~CRTSCTS;
#endif
#ifdef CDTR_IFLOW
    settings.c_cflag &= ~CDTR_IFLOW;
#endif
#ifdef CDSR_OFLOW
    settings.c_cflag &= ~CDSR_OFLOW;
#endif
#ifdef CCAR_OFLOW
    settings.c_cflag &= ~CCAR_OFLOW;
#endif
    settings.c_cflag &= ~HUPCL;
    settings.c_cc[VMIN]=0;settings.c_cc[VTIME]=0;
    speed_t rate=speed(baud);
#ifndef __APPLE__
    if (!rate) { snprintf(error,cap,"Unsupported serial baud rate: %d",baud);close(fd);return NULL; }
#endif
    if (!rate) rate=B38400;
    if (cfsetispeed(&settings,rate)<0||cfsetospeed(&settings,rate)<0||tcsetattr(fd,TCSANOW,&settings)<0) {
        problem(error,cap,"Configure serial port");close(fd);return NULL;
    }
#ifdef __APPLE__
    if (!speed(baud)) { speed_t custom=(speed_t)baud;if (ioctl(fd,IOSSIOSPEED,&custom)<0) { problem(error,cap,"Set serial speed");tcsetattr(fd,TCSANOW,&previous);close(fd);return NULL; } }
#endif
    int bits=0;
    if (ioctl(fd,TIOCMGET,&bits)==0) {
        bits=dtr?(bits|TIOCM_DTR):(bits&~TIOCM_DTR);
        bits=rts?(bits|TIOCM_RTS):(bits&~TIOCM_RTS);
        if (ioctl(fd,TIOCMSET,&bits)<0) { problem(error,cap,"Set DTR/RTS");tcsetattr(fd,TCSANOW,&previous);close(fd);return NULL; }
    } else {
        int reason=errno;
        const char *name=ttyname(fd);
        int pseudo=name && (!strncmp(name,"/dev/pts/",9) || !strncmp(name,"/dev/ttys",9));
        if (!pseudo || (reason!=ENOTTY && reason!=EINVAL)) {
            errno=reason;problem(error,cap,"Read DTR/RTS");tcsetattr(fd,TCSANOW,&previous);close(fd);return NULL;
        }
    } /* PTYs do not have modem-control lines. */
    tcflush(fd,TCIOFLUSH);
#ifdef TIOCEXCL
    if (ioctl(fd,TIOCEXCL)<0 && errno!=ENOTTY) { problem(error,cap,"Lock serial port");tcsetattr(fd,TCSANOW,&previous);close(fd);return NULL; }
#endif
    dw_serial *port=malloc(sizeof(*port));
    if (!port) { snprintf(error,cap,"Out of memory");tcsetattr(fd,TCSANOW,&previous);close(fd);return NULL; }
    port->fd=fd;port->previous=previous;return port;
}
int dw_serial_read(dw_serial *port,uint8_t *data,int count,char *error,size_t cap) {
    struct pollfd descriptor={port->fd,POLLIN,0};int result;
    do { result=poll(&descriptor,1,100); } while (result<0&&errno==EINTR);
    if (result<0) { problem(error,cap,"Poll serial port");return -1; }
    if (!result) return 0;
    if (descriptor.revents&(POLLERR|POLLHUP|POLLNVAL)) { snprintf(error,cap,"Serial port disconnected");return -1; }
    ssize_t received=read(port->fd,data,(size_t)count);
    if (received<0 && (errno==EAGAIN||errno==EINTR)) return 0;
    if (received<0) { problem(error,cap,"Read serial port");return -1; }
    return (int)received;
}
int dw_serial_write(dw_serial *port,const uint8_t *data,int count,char *error,size_t cap) {
    struct pollfd descriptor={port->fd,POLLOUT,0};int result;
    do { result=poll(&descriptor,1,2000); } while (result<0&&errno==EINTR);
    if (result<0) { problem(error,cap,"Poll serial output");return -1; }
    if (!result) { snprintf(error,cap,"Serial write timed out");return -1; }
    if (descriptor.revents&(POLLERR|POLLHUP|POLLNVAL)) { snprintf(error,cap,"Serial port disconnected");return -1; }
    ssize_t sent=write(port->fd,data,(size_t)count);
    if (sent<0 && (errno==EAGAIN||errno==EINTR)) return 0;
    if (sent<0) { problem(error,cap,"Write serial port");return -1; }
    return (int)sent;
}
void dw_serial_cancel(dw_serial *port) { (void)port; }
void dw_serial_close(dw_serial *port) {
    tcsetattr(port->fd,TCSANOW,&port->previous);
#ifdef TIOCNXCL
    ioctl(port->fd,TIOCNXCL);
#endif
    close(port->fd);free(port);
}
int dw_serial_ports(char *out,size_t cap,char *error,size_t error_cap) {
#ifdef __APPLE__
    const char *patterns[]={"/dev/cu.*",NULL};
#else
    const char *patterns[]={"/dev/serial/by-id/*","/dev/ttyUSB*","/dev/ttyACM*","/dev/ttyS*","/dev/ttyAMA*","/dev/ttyTHS*","/dev/rfcomm*",NULL};
#endif
    size_t used=0;
    for (int i=0;patterns[i];++i) {
        glob_t matches={0};int result=glob(patterns[i],0,NULL,&matches);
        if (result!=0 && result!=GLOB_NOMATCH) { globfree(&matches);snprintf(error,error_cap,"Cannot enumerate serial ports");return -1; }
        for (size_t j=0;j<matches.gl_pathc;++j) {
            size_t length=strlen(matches.gl_pathv[j]);
            if (used+length+1<cap) { memcpy(out+used,matches.gl_pathv[j],length);used+=length;out[used++]='\n'; }
        }
        globfree(&matches);
    }
    out[used]=0;return (int)used;
}
#endif
