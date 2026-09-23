// Headless stand-in for BeebEm's BeebWin: what the emulation core calls, and a line
// buffer the video code paints into, which the harness saves as an image.
#pragma once
#include <windows.h>
#include <string>
#include <vector>
#include <stdint.h>
#include "Model.h"
#include "Video.h"
#include "DiscType.h"
#include "Port.h"
union EightUChars { unsigned char data[8]; EightByteType eightbyte; };
union SixteenUChars { unsigned char data[16]; EightByteType eightbytes[2]; };
struct LEDType { bool ShiftLock; bool CapsLock; bool Motor; bool FloppyDisc[2]; bool HDisc[4]; bool ShowDisc; bool ShowKB; };
extern LEDType LEDs;
class CArm; class CSprowCoPro;
extern CArm *arm;
extern CSprowCoPro *sprow;
enum class LEDColour { Red, Green };
enum class MessageType { Error, Warning, Info, Question, Confirm };
enum class MessageResult { None, Yes, No, OK, Cancel };
class BeebWin {
public:
	static const int SCREEN_LINES = MAX_VIDEO_SCAN_LINES + 8;
	char *m_screen, *m_field;   // m_field: the last complete TV field (copied at StartOfFrame)
	std::string m_UserDataPath, m_AppPath;
	bool m_ShiftBooted = false, m_TranslateCRLF = false, m_TextToSpeechEnabled = false;
	double m_RealTimeTarget = 0;
	std::vector<char> m_ClipboardBuffer; size_t m_ClipboardLength = 0, m_ClipboardIndex = 0;
	unsigned char m_DriveControl = 0;
	int m_Frames = 0;
	BeebWin(const char *userdata) : m_UserDataPath(userdata), m_AppPath(userdata) {
		if (m_UserDataPath.back() != '/') m_UserDataPath += '/';
		m_AppPath = m_UserDataPath;
		m_screen = new char[800 * SCREEN_LINES + 4096]; memset(m_screen, 0, 800 * SCREEN_LINES + 4096);
		m_field = new char[800 * SCREEN_LINES]; memset(m_field, 0, 800 * SCREEN_LINES);
	}
	MessageResult Report(MessageType, const char *fmt, ...) { va_list a; va_start(a, fmt); fprintf(stderr, "[beebem] "); vfprintf(stderr, fmt, a); fprintf(stderr, "\n"); va_end(a); return MessageResult::OK; }
	void ReportError(const char *fmt, ...) { va_list a; va_start(a, fmt); fprintf(stderr, "[beebem error] "); vfprintf(stderr, fmt, a); fprintf(stderr, "\n"); va_end(a); }
	void doLED(int, bool) {}
	bool LoadFDC(char *, bool) { return false; }
	void UpdateLines(int, int) {}
	void doHorizLine(int Colour, int y, int sx, int width) {
		if (TeletextEnabled) y /= TeletextStyle;
		long d = ((long)y * 800) + sx + ScreenAdjust + (TeletextEnabled ? 36 : 0);
		if ((d + width) > (500L * 800)) return; if (d < 0) return;
		memset(m_screen + d, Colour, width);
	}
	void doInvHorizLine(int Colour, int y, int sx, int width) {
		if (TeletextEnabled) y /= TeletextStyle;
		long d = ((long)y * 800) + sx + ScreenAdjust + (TeletextEnabled ? 36 : 0);
		if ((d + width) > (500L * 800)) return; if (d < 0) return;
		for (int n = 0; n < width; n++) m_screen[d + n] ^= Colour;
	}
	EightUChars *GetLinePtr(int y) {
		long d = ((long)y * 800) + ScreenAdjust;
		if (d > MAX_VIDEO_SCAN_LINES * 800L || d < 0) return (EightUChars *)(m_screen + MAX_VIDEO_SCAN_LINES * 800);
		return (EightUChars *)(m_screen + d);
	}
	SixteenUChars *GetLinePtr16(int y) { return (SixteenUChars *)GetLinePtr(y); }
	int StartOfFrame() { m_Frames++; memcpy(m_field, m_screen, 800 * SCREEN_LINES); return 0; }   // once per TV field: keep the field just finished; 0: paint the next
	void EndVideo() {}
	void ClearClipboardBuffer() { m_ClipboardBuffer.clear(); m_ClipboardLength = m_ClipboardIndex = 0; }
	void PrintChar(unsigned char) {}
	void SpeakChar(unsigned char) {}
	void SetDriveControl(unsigned char v) { m_DriveControl = v; }
	unsigned char GetDriveControl() { return m_DriveControl; }
	bool Load8271DiscImage(const char *, int, int, DiscType) { return false; }
	bool Load1770DiscImage(const char *, int, DiscType) { return false; }
	void SaveBeebEmID(FILE *) {}
	void SaveEmuUEF(FILE *) {}
	void LoadEmuUEF(FILE *, int) {}
	const char *GetAppPath() const { return m_AppPath.c_str(); }
	const char *GetUserDataPath() const { return m_UserDataPath.c_str(); }
};
