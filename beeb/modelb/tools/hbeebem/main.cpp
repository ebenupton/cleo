// Headless BeebEm harness: boot the Model B disc, skip the title the way the jsbeeb
// tools do (bopen.mjs), run N frames of the same key script, and print the game's
// state at every frame_top -- plus, at one frame, BeebEm's own rendering of the
// screen and the display RAM behind it.  Compared against jsbeeb's bdump.mjs.
//   hbeebem --userdata DIR --disc cleob.ssd --labels labels.txt [--frames N] [--seed S]
//           [--level L] [--shot F] [--out PREFIX]
#include <windows.h>
#include <map>
#include <string>
#include <fstream>
#include <sstream>
#include <vector>
#include "Main.h"
#include "BeebWin.h"
#include "6502core.h"
#include "BeebMem.h"
#include "SysVia.h"
#include "UserVia.h"
#include "Video.h"
#include "Disc8271.h"
#include "Disc1770.h"
#include "Model.h"

Model MachineType = Model::B;
BeebWin *mainWin = nullptr;

static std::map<std::string, int> labels;
static int L(const char *n) { auto i = labels.find(n); if (i == labels.end()) { fprintf(stderr, "no label %s\n", n); exit(2); } return i->second; }
static int pbank = 0;
static int socketOf(int bank) { return WholeRam[pbank + bank - 4]; }  // PBANK (low BSS): filled by start7
static unsigned char rd(int a) { return a < 0x8000 ? WholeRam[a] : (a < 0xC000 ? Roms[ROMSEL][a - 0x8000] : WholeRam[a]); }
static unsigned char rdbank(int bank, int a) { return Roms[socketOf(bank)][a - 0x8000]; }
static void wrbank(int bank, int a, unsigned char v) { Roms[socketOf(bank)][a - 0x8000] = v; }
static long instr = 0;
extern FILE *VideoLog;
static bool trace = getenv("HBTRACE") != nullptr;
static bool runTo(int pc, int bank, long budget) {
  for (long i = 0; i < budget; i++) { Exec6502Instruction(); instr++; if (ProgramCounter == pc && (!bank || ROMSEL == socketOf(bank))) return true;
    if (trace && (i % 2000000) == 0) fprintf(stderr, "  [%ld] pc %04x romsel %d cycles %lld\n", instr, ProgramCounter, ROMSEL, (long long)TotalCycles); }
  return false;
}
static void runCycles(long n) { CycleCountT end = TotalCycles + n; while (TotalCycles < end) { Exec6502Instruction(); instr++; } }
static uint32_t fnv(const unsigned char *p, size_t n) { uint32_t h = 2166136261u; for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 16777619u; } return h; }

int main(int argc, char **argv) {
  std::string userdata, disc, labelsFile, out = "hb"; int frames = 100, seed = 1, level = 0, shot = -1, every = 0;
  for (int i = 1; i < argc; i++) { std::string a = argv[i]; auto v = [&]{ return std::string(argv[++i]); };
    if (a == "--userdata") userdata = v(); else if (a == "--disc") disc = v(); else if (a == "--labels") labelsFile = v();
    else if (a == "--frames") frames = atoi(v().c_str()); else if (a == "--seed") seed = atoi(v().c_str());
    else if (a == "--level") level = atoi(v().c_str()); else if (a == "--shot") shot = atoi(v().c_str()); else if (a == "--shotevery") every = atoi(v().c_str()); else if (a == "--out") out = v(); }
  { std::ifstream f(labelsFile); std::string t, addr, name; while (f >> t >> addr >> name) if (t == "al") labels[name.substr(1)] = std::stoi(addr, nullptr, 16); }
  pbank = L("PBANK");
  mainWin = new BeebWin(userdata.c_str());
  { std::string cfg = std::string(mainWin->GetUserDataPath()) + "Roms.cfg";   // the front end does this in BeebEm
    if (!RomConfig.Load(cfg.c_str())) { fprintf(stderr, "cannot load %s\n", cfg.c_str()); return 2; } }
  BeebMemInit(true, false);
  Init6502Core(); SysVIAReset(); UserVIAReset(); VideoInit(); Disc8271Reset();
  Disc8271Enabled = true; NativeFDC = true;
  if (LoadSimpleDiscImage(disc.c_str(), 0, 0, 80) != Disc8271Result::Success) { fprintf(stderr, "disc load failed\n"); return 2; }
  fprintf(stderr, "RAM banks:"); for (int b = 0; b < 16; b++) if (RomWritable[b]) fprintf(stderr, " %d", b); fprintf(stderr, "\n");
  // SHIFT+BREAK: shift is row 0, column 0 of the matrix
  BeebKeyDown(0, 0); runCycles(2000000); BeebKeyUp(0, 0);
  // the title loop, in bank 7
  if (!runTo(L("title_loop"), 7, 400000000L)) { fprintf(stderr, "no title_loop (pc %04x romsel %d)\n", ProgramCounter, ROMSEL); return 3; }
  fprintf(stderr, "title_loop after %ld instructions; PBANK %d %d %d %d board %d\n", instr, socketOf(4), socketOf(5), socketOf(6), socketOf(7), WholeRam[pbank + 4]);
  { int tl = L("title_loop"); for (int i = 0; i < 6; i++) wrbank(7, tl + i, 0xEA); wrbank(7, tl + 3, 0xA9); wrbank(7, tl + 4, 0);
    int ll = L("level_loop"), lv = L("level"); bool ok = false;
    for (int a = ll; a < ll + 24; a++) if (rdbank(7, a) == 0xA6 && rdbank(7, a + 1) == (lv & 255)) { wrbank(7, a, 0xA2); wrbank(7, a + 1, level); ok = true; break; }
    if (!ok) { fprintf(stderr, "ldx level not found\n"); return 3; } }
  if (!runTo(L("level_init"), 7, 2000000000L)) { fprintf(stderr, "no level_init\n"); return 3; }
  wrbank(7, L("scan_keys"), 0x60);
  if (!runTo(L("frame_top"), 7, 400000000L)) { fprintf(stderr, "no frame_top\n"); return 3; }
  // the state, as bdiff.mjs reads it
  const char *zp[] = {"px","py","vx","vy","anim","evframe","facing","running","firing","hurt","control","bx","by","bvx","bvy","bcnt","bactive","bounce","stars","exiting","lives","health","score","frame","wx","wy","lastkeys","gridsh"};
  std::map<std::string,int> two = {{"px",2},{"py",2},{"vx",2},{"vy",2},{"evframe",2},{"bx",2},{"by",2},{"bvx",2},{"bvy",2},{"score",2},{"frame",2},{"wx",2},{"wy",2}};
  int nobj = WholeRam[L("nobj")], objst = L("LV_OBJST"), keysAddr = L("keys");
  uint32_t rng = seed; auto rnd = [&]{ rng = rng * 1103515245u + 12345u; return rng >> 16; };
  int keys = 0, hold = 0; const int keyset[10] = {0, 1, 2, 2|4, 1|4, 4, 16, 2|16, 1|16, 8};
  for (int f = 0; f < frames; f++) {
    if (hold-- <= 0) { keys = keyset[rnd() % 10]; hold = 4 + rnd() % 40; }
    WholeRam[keysAddr] = keys;
    if (!runTo(L("frame_top"), 7, 40000000L)) { fprintf(stderr, "frame %d: no frame_top\n", f); return 4; }
    std::ostringstream o; o << "f=" << f << " k=" << keys;
    for (const char *n : zp) { int a = L(n); int v = two.count(n) ? WholeRam[a] | (WholeRam[a+1] << 8) : WholeRam[a]; o << " " << n << "=" << v; }
    for (int k = 0; k < 16; k++) { o << " O" << k << "="; for (int i = 0; i < nobj; i++) o << (i ? "," : "") << (int)rdbank(7, objst + k * 149 + i); }
    o << " disp=" << std::hex << fnv(WholeRam + 0x300, 0x7D00) << std::dec;
    o << " crtc=" << (int)CRTC_HorizontalTotal << "," << (int)CRTC_VerticalTotal << "," << (int)CRTC_VerticalDisplayed << "," << (int)CRTC_VerticalSyncPos << "," << (int)CRTC_InterlaceAndDelay << "," << (int)CRTC_ScanLinesPerChar << "," << (int)CRTC_ScreenStartHigh << "," << (int)CRTC_ScreenStartLow;
    printf("%s\n", o.str().c_str());
    if (f == shot || (every && f % every == 0)) {
      // the picture: the field the CRTC finishes next -- at the game's vsync interrupt
      // (its vsyncs counter moves), which jsbeeb's bdump.mjs waits for too
      std::string fo = out + "_f" + std::to_string(f);
      VideoLog = fopen((fo + ".vlog").c_str(), "w");
      { int va = L("vsyncs"); unsigned char v0 = WholeRam[va]; long n = 0; while (WholeRam[va] == v0 && n < 4000000) { Exec6502Instruction(); n++; } }
      fclose(VideoLog); VideoLog = nullptr;
      { std::ofstream t(fo + ".sectab"); int st = L("SECTAB"), cb = WholeRam[L("curbuf")], ds = WholeRam[L("DISPSECT")];
        t << "palette="; for (int i = 0; i < 16; i++) t << (int)VideoULA_Palette[i] << (i < 15 ? "," : ""); t << "\n";
        t << "curbuf=" << cb << " DISPSECT=" << ds << " wfine=" << (int)WholeRam[L("wfine")] << " barq=" << (int)WholeRam[L("barq")] << " ringS=" << (WholeRam[L("ringS")] | WholeRam[L("ringS")+1] << 8) << "\n";
        for (int b = 0; b < 2; b++) for (int e = 0; e < 6; e++) { t << "buf" << b << " sec" << e << ":"; for (int k = 0; k < 8; k++) t << " " << (int)rdbank(7, st + b * 48 + e * 8 + k); t << "\n"; } }
      { std::ofstream d(fo + ".dispram", std::ios::binary); d.write((char *)WholeRam + 0x300, 0x7D00); }
      { std::ofstream p(fo + ".ppm", std::ios::binary); p << "P6\n800 " << MAX_VIDEO_SCAN_LINES << "\n255\n";
        static const unsigned char pal[8][3] = {{0,0,0},{255,0,0},{0,255,0},{255,255,0},{0,0,255},{255,0,255},{0,255,255},{255,255,255}};
        for (int y = 0; y < MAX_VIDEO_SCAN_LINES; y++) for (int x = 0; x < 800; x++) { unsigned c = (unsigned char)mainWin->m_screen[y * 800 + x] & 7; p.write((char *)pal[c], 3); } }

    }
  }
  return 0;
}
