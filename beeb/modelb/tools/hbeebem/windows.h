// Shim for BeebEm's core on macOS: only the types and few calls the emulation core
// uses.  Anything GUI is stubbed in BeebWin.h / stubs.cpp.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <unistd.h>
#include <time.h>
typedef uint32_t DWORD; typedef uint16_t WORD; typedef uint8_t BYTE; typedef int BOOL;
typedef unsigned int UINT; typedef long LONG; typedef char *LPSTR; typedef const char *LPCSTR;
typedef void *HANDLE; typedef intptr_t INT_PTR; typedef uintptr_t UINT_PTR; typedef long LRESULT; typedef uintptr_t WPARAM; typedef intptr_t LPARAM; typedef void *HBITMAP; typedef void *HFONT; typedef void *HBRUSH; typedef void *HPEN; typedef void *HICON; typedef void *HCURSOR; typedef void *HGDIOBJ; typedef void *HMODULE; typedef void *HKEY; typedef void *LPVOID; typedef DWORD COLORREF; typedef struct { LONG left, top, right, bottom; } RECT; typedef struct { LONG x, y; } POINT; typedef void *HGLOBAL; typedef void *HRSRC; typedef void *HWND; typedef void *HDC; typedef void *HINSTANCE; typedef void *HMENU;
typedef union { struct { DWORD LowPart; LONG HighPart; }; int64_t QuadPart; } LARGE_INTEGER;
#ifndef MAX_PATH
#define MAX_PATH 1024
#endif
#define _MAX_PATH MAX_PATH
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif
#define __int64 int64_t
#define _stricmp strcasecmp
#define _strnicmp strncasecmp
#define _strdup strdup
#define _snprintf snprintf
#define _vsnprintf vsnprintf
#define sprintf_s snprintf
#define _fseeki64 fseeko
#define _ftelli64 ftello
static inline int strcpy_s(char *d, size_t n, const char *s) { strncpy(d, s, n); d[n-1] = 0; return 0; }
static inline int strcat_s(char *d, size_t n, const char *s) { strncat(d, s, n - strlen(d) - 1); return 0; }
static inline DWORD GetTickCount() { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (DWORD)(t.tv_sec * 1000 + t.tv_nsec / 1000000); }
static inline void Sleep(DWORD ms) { usleep(ms * 1000); }
#define MessageBox(...) 0
#define OutputDebugString(s) ((void)0)

#define CALLBACK
#define WINAPI
#define APIENTRY
#define ZeroMemory(p, n) memset((p), 0, (n))
typedef struct { WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; } SYSTEMTIME;
static inline void GetLocalTime(SYSTEMTIME *t) { time_t n = time(0); struct tm *l = localtime(&n); t->wYear = l->tm_year + 1900; t->wMonth = l->tm_mon + 1; t->wDayOfWeek = l->tm_wday; t->wDay = l->tm_mday; t->wHour = l->tm_hour; t->wMinute = l->tm_min; t->wSecond = l->tm_sec; t->wMilliseconds = 0; }
#define GetSystemTime GetLocalTime
#include "SoundStreamerType.h"
