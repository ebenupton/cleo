// Portable FileUtils for the headless build (the original uses shlwapi).
#include <windows.h>
#include <string>
#include <sys/stat.h>
#include <stdarg.h>
#include "FileUtils.h"
bool FileExists(const char* p) { struct stat st; return stat(p, &st) == 0 && S_ISREG(st.st_mode); }
bool FolderExists(const char* p) { struct stat st; return stat(p, &st) == 0 && S_ISDIR(st.st_mode); }
std::string AppendPath(const std::string& b, const std::string& p) { if (b.empty()) return p; if (b.back() == '/') return b + p; return b + "/" + p; }
bool HasFileExt(const char* f, const char* e) { size_t lf = strlen(f), le = strlen(e); return lf >= le && strcasecmp(f + lf - le, e) == 0; }
std::string ReplaceFileExt(const std::string& f, const char* e) { size_t d = f.rfind('.'), s = f.rfind('/'); if (d == std::string::npos || (s != std::string::npos && d < s)) return f + e; return f.substr(0, d) + e; }
void GetPathFromFileName(const char* f, char* p, size_t n) { strncpy(p, f, n); p[n-1] = 0; char *s = strrchr(p, '/'); if (s) *s = 0; else p[0] = 0; }
const char* GetFileNameFromPath(const char* p) { const char *s = strrchr(p, '/'); return s ? s + 1 : p; }
void MakeFileName(char* p, size_t n, const char* d, const char* f, ...) { char buf[MAX_PATH]; va_list a; va_start(a, f); vsnprintf(buf, sizeof buf, f, a); va_end(a); snprintf(p, n, "%s%s%s", d, (d[0] && d[strlen(d)-1] != '/') ? "/" : "", buf); }
void MakePreferredPath(char* p) { for (char *c = p; *c; c++) if (*c == '\\') *c = '/'; }
void AppendPath(char* p, const char* a) { size_t l = strlen(p); if (l && p[l-1] != '/') strcat(p, "/"); strcat(p, a); }
bool IsRelativePath(const char* p) { return p[0] != '/'; }
