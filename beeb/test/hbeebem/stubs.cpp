// Headless BeebEm: the peripherals the core links against but this harness never uses.
#include <windows.h>
#include "Arm.h"
#include "SprowCoPro.h"
#include "Master512CoPro.h"
#include "Debug.h"
#include "Econet.h"
#include "Ide.h"
#include "Music5000.h"
#include "Rtc.h"
#include "Sasi.h"
#include "Scsi.h"
#include "Serial.h"
#include "Sound.h"
#include "Teletext.h"
#include "Tube.h"
#include "UserPortBreakoutBox.h"
#include "UserPortRTC.h"
#include "BeebWin.h"
#include "6502core.h"
LEDType LEDs;
CArm *arm = nullptr;
CSprowCoPro *sprow = nullptr;
void CArm::exec(int) {}
void CArm::LoadState(FILE *, int) {}
void CArm::SaveState(FILE *) {}
void CSprowCoPro::Execute(int) {}
void CSprowCoPro::LoadState(FILE *) {}
void CSprowCoPro::SaveState(FILE *) {}
void Master512CoPro::Execute(int) {}
void Master512CoPro::LoadState(FILE *) {}
void Master512CoPro::SaveState(FILE *) {}
void UserPortBreakoutDialog::ShowInputs(unsigned char) {}
void UserPortBreakoutDialog::ShowOutputs(unsigned char) {}
bool DebugDisassembler(int, int, int, int, int, unsigned char, unsigned char, bool) { return true; }   // true: not halted (the core would Sleep otherwise)
void DebugDisplayInfo(const char *) {}
void DebugDisplayInfoF(const char *, ...) {}
void DebugDisplayTrace(DebugType, bool, const char *) {}
void DebugDisplayTraceF(DebugType, bool, const char *, ...) {}
void DebugInitMemoryMaps() {}
bool DebugLoadMemoryMap(const char *, int) { return false; }
bool EconetInterruptRequest() { return false; }
bool EconetPoll() { return false; }
unsigned char EconetRead(unsigned char) { return 0; }
unsigned char EconetReadStationID() { return 0; }
void EconetWrite(unsigned char, unsigned char) {}
unsigned char IDERead(int) { return 0; }
void IDEWrite(int, unsigned char) {}
void Load65C02MemUEF(FILE *) {}
void Load65C02UEF(FILE *) {}
void LoadMusic5000JIMPageRegUEF(FILE *) {}
void LoadMusic5000UEF(FILE *, int) {}
void LoadSerialUEF(FILE *, int) {}
void LoadSoundUEF(FILE *) {}
void LoadTubeUEF(FILE *) {}
void LoadZ80UEF(FILE *) {}
bool Music5000Read(int, unsigned char *) { return false; }
void Music5000Update(unsigned int) {}
void Music5000Write(int, unsigned char) {}
void PlaySoundSample(int, bool) {}
void RTCChipEnable(bool) {}
bool RTCIsChipEnable() { return false; }
unsigned char RTCReadData() { return 0; }
void RTCWriteAddress(unsigned char) {}
void RTCWriteData(unsigned char) {}
unsigned char ReadTorchTubeFromHostSide(int) { return 0; }
unsigned char ReadTubeFromHostSide(int) { return 0; }
unsigned char SASIRead(int) { return 0; }
void SASIWrite(int, unsigned char) {}
unsigned char SCSIRead(int) { return 0; }
void SCSIWrite(int, unsigned char) {}
void Save65C02MemUEF(FILE *) {}
void Save65C02UEF(FILE *) {}
void SaveMusic5000UEF(FILE *) {}
void SaveSerialUEF(FILE *) {}
void SaveSoundUEF(FILE *) {}
void SaveTubeUEF(FILE *) {}
void SaveZ80UEF(FILE *) {}
unsigned char SerialACIAReadRxData() { return 0; }
unsigned char SerialACIAReadStatus() { return 0; }
void SerialACIAWriteControl(unsigned char) {}
void SerialACIAWriteTxData(unsigned char) {}
void SerialPoll(int) {}
unsigned char SerialULARead() { return 0; }
void SerialULAWrite(unsigned char) {}
void SoundPoll() {}
void Sound_RegWrite(int) {}
void StopSoundSample(int) {}
void SyncTubeProcessor() {}
void TeletextAdapterUpdate() {}
unsigned char TeletextRead(int) { return 0; }
void TeletextWrite(int, int) {}
int UserPortRTCReadBit() { return 0; }
void UserPortRTCResetWrite() {}
void UserPortRTCWrite(unsigned char) {}
void WrapTubeCycles() {}
void WriteTorchTubeFromHostSide(int, unsigned char) {}
void WriteTubeFromHostSide(int, unsigned char) {}
bool DebugEnabled = true;   // makes Exec6502Instruction run ONE instruction per call (Count = 1), which the harness needs for its breakpoints
bool DiscDriveSoundEnabled = false;
bool EconetEnabled = false;
void Z80Execute() {}
SerialTapeState SerialGetTapeState() { return SerialTapeState::NoTape; }
CycleCountT IP232RxTrigger = CycleCountTMax, TapeTrigger = CycleCountTMax;
Master512CoPro::Master512CoPro() {}
Master512CoPro::~Master512CoPro() {}
Master512CoPro master512CoPro;
TubeDevice TubeType = TubeDevice::None;
UserPortBreakoutDialog *userPortBreakoutDialog = nullptr;
bool EconetNMIEnabled = false, IDEDriveEnabled = false, Music5000Enabled = false, SCSIDriveEnabled = false, UserPortRTCEnabled = false;
char FDCDLL[256] = "";
int EconetFlagFillTimeoutTrigger = 0x7fffffff, EconetTrigger = 0x7fffffff, SoundTrigger = 0x7fffffff, TeletextAdapterTrigger = 0x7fffffff;
