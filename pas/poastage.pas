{ Ported from PJA's pas/pjastage.pas via PMPA (pas/pmpastage.pas).

  Where a file's time goes: read, parse, encode, verify, decode, hash and
  write, for the command's --stats and bench (doc/CLI.md).

  Each thread keeps its own account. StageEnter closes the stage running
  and opens another; poapack calls it around the scan, the coder, the
  check and the hash, and it costs nothing while StagesOn is False, as it
  is unless the command asks. }
unit poastage;

{$I poa.inc}
{$ifopt R-}{$fatal poastage: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poastage: overflow checks ($Q+) are mandatory}{$endif}

interface

type
  TStage = (stNone, stRead, stParse, stEncode, stVerify, stDecode, stHash, stWrite);
  TStageTimes = array[TStage] of Double;

const
  STAGE_NAMES: array[TStage] of string = ('other', 'read', 'parse', 'encode', 'verify', 'decode', 'hash', 'write');

var
  { set once, before any work starts }
  StagesOn: Boolean = False;

{ seconds since some fixed point, to the microsecond }
function Seconds: Double;
{ closes the stage running in this thread and opens s; returns the one closed }
function StageEnter(s: TStage): TStage;
{ this thread's account back to zero, no stage open }
procedure StageReset;
{ this thread's account so far (the stage running included) }
function StageTimes: TStageTimes;

implementation

uses
  {$ifdef UNIX} Unix, BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  SysUtils;

threadvar
  stageNow: TStage;
  stageSince: Double;
  stageSum: TStageTimes;

{$ifdef MSWINDOWS}
var qpcFreq: Int64 = 0;
{$endif}

function Seconds: Double;
{$ifdef UNIX} var tv: TTimeVal; {$endif}
{$ifdef MSWINDOWS} var c: Int64; {$endif}
begin
  {$ifdef UNIX}
  fpgettimeofday(@tv, nil);
  { Double(...): FPC would compute with 1e6 as a Single, to the second }
  Result := Double(tv.tv_sec) + Double(tv.tv_usec) * Double(0.000001);
  {$else}
  {$ifdef MSWINDOWS}
  QueryPerformanceCounter(c);
  Result := c / qpcFreq;
  {$else}
  Result := GetTickCount64 / 1000;
  {$endif}
  {$endif}
end;

function StageEnter(s: TStage): TStage;
var t: Double;
begin
  Result := stageNow;
  if not StagesOn then Exit;
  t := Seconds;
  if stageNow <> stNone then stageSum[stageNow] := stageSum[stageNow] + (t - stageSince);
  stageNow := s;
  stageSince := t;
end;

procedure StageReset;
var s: TStage;
begin
  for s := Low(TStage) to High(TStage) do stageSum[s] := 0;
  stageNow := stNone;
  stageSince := Seconds;
end;

function StageTimes: TStageTimes;
begin
  StageEnter(stageNow);
  Result := stageSum;
end;

{$ifdef MSWINDOWS}
initialization
  QueryPerformanceFrequency(qpcFreq);
  if qpcFreq = 0 then qpcFreq := 1;
{$endif}
end.
