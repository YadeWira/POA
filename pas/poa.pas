{ Ported from PJA's pas/pjacli.pas via PMPA (pas/pmpacli.pas).

  The poa command: Ogg files to .poa and back. doc/CLI.md has the
  switches and the reasons behind them.

    poa a [options] FILE...     compress: song.ogg -> song.ogg.poa
    poa x [options] FILE...     extract:  song.ogg.poa -> song.ogg (the .poa's name without .poa)
    poa list FILE...            what each .poa holds
    poa t FILE...               test: extract and verify, write nothing
    poa info FILE...            the structure of each file, and what POA does with it
    poa report [FILE]           a bug report, and a link to open an issue with it
    poa bench FILE...           how fast this machine compresses and extracts them
    poa selftest                the samples inside the binary
    poa --version               the build and the system

  Nothing is written under an output's name unless it verified: `a` checks
  that its stream decompresses to the input, `x` that the size and the hash
  match. An existing output is only replaced with -f. }
program poa;

{$I poa.inc}
{$ifopt R-}{$fatal poacli: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poacli: overflow checks ($Q+) are mandatory}{$endif}

uses
  {$ifdef UNIX} cthreads, BaseUnix, {$endif}
  {$ifdef MSWINDOWS} Windows, {$endif}
  SysUtils, Classes, poablake3, poaformat, poaside, poapack, poafs, poathread, poalimits,
  { the commands for reporting and checking (doc/CLI.md); each format's
    info provider registers itself, the .poa's first (a stored .poa holds
    Ogg pages) }
  poastage, poainfo, poainfopoa, poainfoogg, poasysinfo, poareport, poabench, poaselftest;

type
  TCommand = (cmNone, cmCompress, cmExtract, cmList, cmTest, cmInfo, cmReport, cmBench, cmSelftest);

var
  command: TCommand;
  inputs: TStringList;
  outArg: string;          { -o: a name, or a directory }
  outDir: string;          { --output-dir }
  force, keepCorrupt, dryRun, quiet, noVerify, cleanTemps: Boolean;
  threads: Integer;
  { --stats, --json; report's --with-file; bench's -r }
  stats, jsonOut, withFile: Boolean;
  runs: Integer;
  runsGiven: Boolean;
  { -th or --threads given }
  thGiven: Boolean;
  { --cpu }
  cpuGiven: Boolean;
  cpuWanted: TCpuPath;
  { files that met a bug (an exception that is not about the file) }
  bugs: Integer;
  bugFile: string;
  maxOutput: QWord;
  errors: Integer;

type
  { One input: what it printed and whether it failed. Files are processed
    in parallel, and their lines come out in the order of the inputs. }
  TFileJob = record
    name, outText, errText: string;
    index: Integer;
    failed, done: Boolean;
    { an exception that is a bug in POA, not something about the file }
    bug: Boolean;
    { --json: the object of this file; errors: what failed, for it }
    node: TInfoNode;
    errors: string;
    { the bytes read and written (the summary of --stats and --json) }
    inBytes, outBytes: Int64;
    { the input's size when the files were ordered (0: not looked at) }
    size: Int64;
    { its output handed to the committer (Defer): the job ends there }
    deferred: Boolean;
  end;
  PFileJob = ^TFileJob;

threadvar
  CurJob: PFileJob;

var
  jobs: array of TFileJob;

var
  { the arguments, in UTF-8 on every system }
  args: array of string;

{$ifdef MSWINDOWS}
function CommandLineToArgvW(cmd: PWideChar; out n: Integer): PPWideChar; stdcall; external 'shell32.dll';

{ ParamStr goes through the ANSI code page on Windows, and a name like
  "canción.ogg" does not survive it: the arguments are read in UTF-16
  and kept in UTF-8, the code page the whole program then runs in (so the
  RTL's file functions and poafs open the right file). }
procedure ReadArgs;
var w: PPWideChar; n, i: Integer;
begin
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  w := CommandLineToArgvW(GetCommandLineW, n);
  args := nil;
  SetLength(args, n);
  for i := 0 to n - 1 do args[i] := UTF8Encode(UnicodeString(w[i]));
  LocalFree(HLOCAL(w));
end;
{ cmd passes a pattern such as *.ogg as it is (Windows leaves that to each
  program): an input with * or ? in its name becomes the files that match,
  in order of name; the folder part is taken as written. A pattern that
  matches nothing stays, and fails as such (ReadWhole). }
procedure ExpandWildcards;
var all, found: TStringList; i: Integer; a, dir: string; sr: TUnicodeSearchRec;
begin
  all := TStringList.Create;
  found := TStringList.Create;
  for i := 0 to inputs.Count - 1 do begin
    a := inputs[i];
    if LastDelimiter('*?', a) <= LastDelimiter('\/:', a) then begin all.Add(a); Continue; end;
    dir := Copy(a, 1, LastDelimiter('\/:', a));
    found.Clear;
    if FindFirst(UnicodeString(UTF8Decode(a)), faAnyFile, sr) = 0 then begin
      repeat
        if sr.Attr and faDirectory = 0 then found.Add(dir + UTF8Encode(sr.Name));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    if found.Count = 0 then all.Add(a)
    else begin
      found.Sort;
      all.AddStrings(found);
    end;
  end;
  found.Free;
  inputs.Free;
  inputs := all;
end;
{$else}
procedure ReadArgs;
var i: Integer;
begin
  args := nil;
  SetLength(args, ParamCount + 1);
  for i := 0 to ParamCount do args[i] := ParamStr(i);
end;
{$endif}

function ArgCount: Integer;
begin Result := High(args); end;

procedure Fail(const msg: string);
begin
  CurJob^.failed := True;
  CurJob^.errText := CurJob^.errText + 'poa: ' + msg + LineEnding;
  if CurJob^.errors <> '' then CurJob^.errors := CurJob^.errors + '; ';
  CurJob^.errors := CurJob^.errors + msg;
end;

{ a line for people: --json prints the file's object instead }
procedure Say(const line: string);
begin
  if jsonOut then Exit;
  CurJob^.outText := CurJob^.outText + line + LineEnding;
end;

{ a field of the file's --json object }
function JobNode: TInfoNode;
begin
  Result := CurJob^.node;
end;

{ an exception about the file or the system (a read, a write, memory),
  not a bug in POA }
function NotABug(e: Exception): Boolean;
begin
  Result := (e is EInOutError) or (e is EStreamError) or (e is EOSError) or (e is EOutOfMemory);
end;

{ What could not be written to the output (a full disk, a closed pipe):
  said once, and what is still in the buffer dropped, or the RTL would
  fail on it again at the end with a runtime error }
procedure OutputFailed(const why: string);
begin
  TextRec(Output).BufPos := 0;
  InOutRes := 0;
  Writeln(StdErr, 'poa: could not write the output: ', why);
end;

{ The end: the output flushed first, so that a write that fails says so
  and ends with 1 (not a bug, and not 0) }
procedure Finish(code: Integer);
begin
  try
    Flush(Output);
  except
    on e: Exception do begin
      OutputFailed(e.Message);
      if code = 0 then code := 1;
    end;
  end;
  Halt(code);
end;

procedure Usage(code: Integer);
begin
  Writeln('poa ', POA_VERSION, ' - lossless recompression of Ogg files (Vorbis, Opus, FLAC, Speex, Theora)');
  Writeln;
  Writeln('usage: poa a [options] FILE...      compress: NAME -> NAME.poa');
  Writeln('       poa x [options] FILE...      extract:  NAME.poa -> NAME');
  Writeln('       poa list FILE...             show what each .poa holds');
  Writeln('       poa t FILE...                test each .poa: extract and verify, write nothing');
  Writeln('       poa info FILE...             the structure of each file, and what POA does with it');
  Writeln('       poa report [FILE] [-o REPORT.txt] [--with-file]');
  Writeln('                                    a bug report (no audio, no comment text) and');
  Writeln('                                    a link to open an issue with it');
  Writeln('       poa bench FILE... [-r N]     time a, a --no-verify and x (best of N runs)');
  Writeln('       poa selftest                 the samples inside poa');
  Writeln('       poa --version, -V            the build and the system');
  Writeln;
  Writeln('  -o PATH              output name (one input), or directory (ends in / or exists)');
  Writeln('  --output-dir=DIR     output directory');
  Writeln('  -f, --force          replace an existing output (only with something that verified)');
  Writeln('  -th N, --threads=N   files worked on at once (default: the processors, up to 8);');
  Writeln('                       a file is coded on one thread');
  Writeln('  --max-output=SIZE    x, t: refuse a declared original above SIZE (256M; 0 = no limit)');
  Writeln('  --keep-corrupt       x: keep output that does not verify as NAME.corrupt');
  Writeln('  --no-verify          a: do not decompress the stream to check it before writing:');
  Writeln('                       faster, but a codec bug would only show when extracting');
  Writeln('                       (the hash catches it then)');
  Writeln('  --no-sync            do not wait for each output to reach the disk: a few');
  Writeln('                       percent faster, but a power cut may leave it empty');
  Writeln('  --clean-temps        delete the temporaries an interrupted run left where');
  Writeln('                       this one writes (only POA''s, old, of no live process)');
  Writeln('  -n, --dry-run        do everything but write');
  Writeln('  -q, --quiet          only errors');
  Writeln('  --stats              a, x, t: where each file''s time went');
  Writeln('  --json               a, x, t, info, list: a JSON object per file, then a summary');
  Writeln('  -r N                 bench: runs of each, the best counts (default 3)');
  Writeln('  --cpu=PATH           the models'' path: plain, the only one POA has');
  Writeln('  --                   the rest are files');
  Writeln;
  Writeln('exit status: 0 all went through, 1 a file failed, 2 usage error, 3 a bug in POA');
  Writeln('bugs: poa report FILE, then ', ISSUES_URL);
  Finish(code);
end;

procedure UsageError(const msg: string);
begin
  Writeln(StdErr, 'poa: ', msg);
  Writeln(StdErr, 'poa: see poa --help');
  Halt(2);
end;

{ "256M", "1G", "1000K", "12345"; False if it is none of those }
function ParseSize(s: string; out v: QWord): Boolean;
var mult: QWord; n: QWord; c: Char;
begin
  Result := False;
  if s = '' then Exit;
  mult := 1;
  c := UpCase(s[Length(s)]);
  case c of
    'K': mult := QWord(1) shl 10;
    'M': mult := QWord(1) shl 20;
    'G': mult := QWord(1) shl 30;
  end;
  if mult > 1 then Delete(s, Length(s), 1);
  if not TryStrToQWord(s, n) then Exit;
  if (n > 0) and (n > High(QWord) div mult) then Exit;
  v := n * mult;
  Result := True;
end;

{ where the command is among the arguments (past a leading --cpu) }
function CommandIndex: Integer;
begin
  Result := 1;
  while (Result < ArgCount) and (Copy(args[Result], 1, 6) = '--cpu=') do Inc(Result);
end;

{ --cpu: the path asked for, or a usage error if this processor (or this
  build) does not have it }
procedure ApplyCpu;
begin
  if not cpuGiven then Exit;
  if not SetCpuPath(cpuWanted) then
    UsageError('--cpu=' + CPU_PATH_NAMES[cpuWanted] + ': this processor or this build does not have it; it has: ' +
               SupportedPaths);
end;

{ "--cpu avx2": the value goes after an equals sign (next: where it is) }
procedure CpuSpaced(next: Integer);
begin
  if next <= ArgCount then UsageError('"--cpu ' + args[next] + '": write --cpu=' + args[next])
  else UsageError('--cpu needs a path: --cpu=plain');
end;

procedure ParseArgs;
var i: Integer; a, v: string; n: Integer; onlyFiles: Boolean;

  function NextValue: string;
  begin
    if i >= ArgCount then UsageError(a + ' needs a value');
    Inc(i);
    Result := args[i];
  end;

begin
  command := cmNone; inputs := TStringList.Create;
  outArg := ''; outDir := ''; force := False; keepCorrupt := False; dryRun := False; quiet := False;
  noVerify := False; cleanTemps := False;
  stats := False; jsonOut := False; withFile := False; runs := 3; runsGiven := False; thGiven := False;
  cpuGiven := False;
  threads := DefaultThreads;
  maxOutput := DEFAULT_MAX_OUTPUT;
  ReadArgs;
  if ArgCount = 0 then Usage(2);
  { --cpu may come before the command too }
  i := 1;
  while (i < ArgCount) and (Copy(args[i], 1, 6) = '--cpu=') do begin
    if not ParseCpuPath(Copy(args[i], 7, MaxInt), cpuWanted) then
      UsageError('--cpu: plain (the only path POA has), not "' + Copy(args[i], 7, MaxInt) + '"');
    cpuGiven := True;
    Inc(i);
  end;
  a := args[i];
  if a = '--cpu' then CpuSpaced(i + 1);
  if (a = '-h') or (a = '--help') then Usage(0);
  if (a = '--version') or (a = '-V') then begin
    ApplyCpu;
    Writeln('poa ', POA_VERSION);
    Write(SystemText(False));
    Finish(0);
  end;
  if a = 'a' then command := cmCompress
  else if a = 'x' then command := cmExtract
  else if a = 'list' then command := cmList
  else if a = 't' then command := cmTest
  else if a = 'info' then command := cmInfo
  else if a = 'report' then command := cmReport
  else if a = 'bench' then command := cmBench
  else if a = 'selftest' then command := cmSelftest
  else UsageError('unknown command "' + a + '": a, x, list, t, info, report, bench or selftest');
  onlyFiles := False;
  i := i + 1;
  while i <= ArgCount do begin
    a := args[i];
    if onlyFiles or (a = '') or (a[1] <> '-') or (a = '-') then inputs.Add(a)
    else if a = '--' then onlyFiles := True
    else if a = '--cpu' then CpuSpaced(i + 1)
    else if (a = '-h') or (a = '--help') then Usage(0)
    else if a = '-o' then outArg := NextValue
    else if Copy(a, 1, 13) = '--output-dir=' then outDir := Copy(a, 14, MaxInt)
    else if (a = '-f') or (a = '--force') then force := True
    else if (a = '-n') or (a = '--dry-run') then dryRun := True
    else if (a = '-q') or (a = '--quiet') then quiet := True
    else if a = '--keep-corrupt' then keepCorrupt := True
    else if a = '--no-verify' then noVerify := True
    else if a = '--clean-temps' then cleanTemps := True
    else if a = '--no-sync' then SyncToDisk := False
    else if a = '--stats' then stats := True
    else if a = '--json' then jsonOut := True
    else if a = '--with-file' then withFile := True
    else if Copy(a, 1, 6) = '--cpu=' then begin
      if not ParseCpuPath(Copy(a, 7, MaxInt), cpuWanted) then
        UsageError('--cpu: plain (the only path POA has), not "' + Copy(a, 7, MaxInt) + '"');
      cpuGiven := True;
    end else if a = '-r' then begin
      v := NextValue;
      if not TryStrToInt(v, n) or (n < 1) or (n > 1000) then UsageError('-r: a number from 1 to 1000, not "' + v + '"');
      runs := n;
      runsGiven := True;
    end else if (a = '-th') or (Copy(a, 1, 10) = '--threads=') then begin
      if a = '-th' then v := NextValue else v := Copy(a, 11, MaxInt);
      if not TryStrToInt(v, n) or (n < 1) or (n > 64) then UsageError('threads: a number from 1 to 64, not "' + v + '"');
      threads := n;
      thGiven := True;
    end else if Copy(a, 1, 13) = '--max-output=' then begin
      if not ParseSize(Copy(a, 14, MaxInt), maxOutput) then
        UsageError('--max-output: a size like 256M, 1G or 0, not "' + Copy(a, 14, MaxInt) + '"');
      if maxOutput = 0 then maxOutput := High(QWord);
    end
    { a glued value (packJPG's old spelling): say what to write instead }
    else if Copy(a, 1, 3) = '-th' then UsageError('"' + a + '": write -th ' + Copy(a, 4, MaxInt))
    else UsageError('unknown option "' + a + '"');
    Inc(i);
  end;
  {$ifdef MSWINDOWS} ExpandWildcards; {$endif}
  if (inputs.Count = 0) and not (command in [cmReport, cmSelftest]) then UsageError('no input files');
  if (outArg <> '') and (outDir <> '') then UsageError('-o and --output-dir together');
  if (command in [cmList, cmTest, cmInfo, cmBench, cmSelftest]) and ((outArg <> '') or (outDir <> '')) then
    UsageError(args[CommandIndex] + ' writes nothing');
  if noVerify and (command <> cmCompress) then UsageError('--no-verify is for a');
  if stats and not (command in [cmCompress, cmExtract, cmTest]) then UsageError('--stats is for a, x and t');
  if jsonOut and not (command in [cmCompress, cmExtract, cmTest, cmInfo, cmList]) then
    UsageError('--json is for a, x, t, info and list');
  if withFile and (command <> cmReport) then UsageError('--with-file is for report');
  if withFile and (inputs.Count = 0) then UsageError('--with-file copies the FILE of the report: give one');
  if runsGiven and (command <> cmBench) then UsageError('-r is for bench');
  if (command in [cmTest, cmInfo, cmReport, cmBench, cmSelftest]) and (force or dryRun or keepCorrupt) then
    UsageError('-f, -n and --keep-corrupt are for a and x');
  { durable writes: list, t, info and selftest write nothing; bench and
    report write, but only their own files (bench in a directory of its own) }
  if (cleanTemps or not SyncToDisk) and (command in [cmList, cmTest, cmInfo, cmSelftest]) then
    UsageError(args[CommandIndex] + ' writes nothing');
  if cleanTemps and not (command in [cmCompress, cmExtract]) then UsageError('--clean-temps is for a and x');
  if (command = cmReport) and (outDir <> '') then UsageError('report: -o names the report');
  if (command = cmReport) and (inputs.Count > 1) then UsageError('report takes one file');
  if (command = cmSelftest) and (inputs.Count > 0) then UsageError('selftest takes no files: its samples are inside');
  if (command = cmSelftest) and thGiven then UsageError('selftest takes no -th: POA codes a file on one thread');
end;

function ReadWhole(const f: string; out data: TBytes): Boolean;
var s: TFileStream;
begin
  data := nil;
  Result := False;
  if DirectoryExists(f) then begin Fail(f + ': is a directory'); Exit; end;
  {$ifdef MSWINDOWS}
  { a pattern still here matched nothing (no Windows name has * or ?) }
  if LastDelimiter('*?', f) > 0 then begin Fail(f + ': no file matches'); Exit; end;
  {$endif}
  StageEnter(stRead);
  try
    s := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      if QWord(s.Size) > MAX_INPUT then begin Fail(f + ': larger than 2 GiB'); Exit; end;
      SetLength(data, s.Size);
      if s.Size > 0 then s.ReadBuffer(data[0], s.Size);
    finally
      s.Free;
    end;
    Result := True;
    CurJob^.inBytes := Length(data);
  except
    on e: Exception do Fail(f + ': ' + e.Message);
  end;
  StageEnter(stNone);
end;

function EndsWithSeparator(const s: string): Boolean;
begin
  Result := (s <> '') and ((s[Length(s)] = '/') or (s[Length(s)] = DirectorySeparator));
end;

{ Where the output of `input` goes, named `name` by default. }
function OutputPath(const input, name: string): string;
var dir: string;
begin
  dir := outDir;
  if outArg <> '' then begin
    if DirectoryExists(outArg) or EndsWithSeparator(outArg) then dir := outArg
    else Exit(outArg);
  end;
  if dir = '' then Result := ExtractFilePath(input) + name
  else Result := IncludeTrailingPathDelimiter(dir) + name;
end;

{ The name x gives what a .poa holds: the .poa's own name without its
  .poa (any case): song.ogg.poa -> song.ogg. A .poa keeps no name nor
  extension of its own. A file not named *.poa gets .out added. }
function XName(const f: string): string;
var name: string;
begin
  name := ExtractFileName(f);
  if (LowerCase(ExtractFileExt(name)) = '.poa') and (Length(name) > 4) then
    Result := Copy(name, 1, Length(name) - 4)
  else Result := name + '.out';
end;

{ The name a gives the .poa of f }
function AName(const f: string): string;
begin
  Result := ExtractFileName(f) + '.poa';
end;

function Human(n: QWord): string;
begin
  if n >= 10 * 1024 * 1024 then Result := Format('%.1f MB', [n / (1024 * 1024)])
  else if n >= 10 * 1024 then Result := Format('%.1f KB', [n / 1024])
  else Result := IntToStr(n) + ' B';
end;

var
  { every output this run has taken, and every input, by PathKey; Objects
    is the job's index }
  outKeys, inKeys: TStringList;
  claimLock: TRTLCriticalSection;

{ The same file for the same text: absolute, without . and .., and on
  Windows without case. Links are not resolved. }
function PathKey(const p: string): string;
begin
  Result := ExpandFileName(p);
  {$ifdef MSWINDOWS} Result := UTF8Encode(WideLowerCase(UTF8Decode(Result))); {$endif}
end;

function NewKeyList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.UseLocale := False;
  Result.Duplicates := dupAccept;
  Result.Sorted := True;
end;

{ Takes path as the output of the current job. Without this, with -f two
  inputs with the same output (the same name from two
  folders with --output-dir) both said they were written, and only the last
  one was there; one could also replace another job's input before it was
  read. False, and the job failed, if the path is another job's. }
function Claim(const path: string): Boolean;
var key: string; i, j, k: Integer;
begin
  key := PathKey(path); k := CurJob^.index;
  Result := False;
  EnterCriticalSection(claimLock);
  try
    if outKeys.Find(key, i) then begin
      j := PtrInt(outKeys.Objects[i]);
      if j <> k then begin Fail(path + ': also the output of ' + jobs[j].name + ' in this run'); Exit; end;
      Exit(True);
    end;
    if inKeys.Find(key, i) then begin
      while (i > 0) and (inKeys[i - 1] = key) do Dec(i);
      while (i < inKeys.Count) and (inKeys[i] = key) do begin
        if PtrInt(inKeys.Objects[i]) <> k then begin Fail(path + ': also an input of this run'); Exit; end;
        Inc(i);
      end;
    end;
    outKeys.AddObject(key, TObject(PtrInt(k)));
    Result := True;
  finally
    LeaveCriticalSection(claimLock);
  end;
end;

{ Anything under that name, a link that leads nowhere included (FileExists
  follows links, and a dangling one said no where the write then failed) }
function Exists(const path: string): Boolean;
{$ifdef UNIX} var st: Stat; {$endif}
begin
  {$ifdef UNIX}
  st := Default(Stat);
  Result := fpLstat(path, st) = 0;
  {$else}
  Result := FileExists(path) or DirectoryExists(path);
  {$endif}
end;

{ Save's checks before the write: the name taken in this run, what an
  interrupted run left, an existing file without -f }
function SaveCheck(const path: string): Boolean;
var note: string;
begin
  Result := False;
  if not Claim(path) then Exit;
  { what an interrupted run left in this directory: a notice, not a failure }
  note := CheckLeftovers(path, cleanTemps and not dryRun);
  if note <> '' then CurJob^.errText := CurJob^.errText + 'poa: ' + note + LineEnding;
  { -n checks this too: it said yes to what the real run then refused }
  if not force and Exists(path) then begin
    Fail(path + ': already exists (-f to replace it)');
    Exit;
  end;
  Result := True;
end;

{ Save's write, after SaveCheck }
function SaveWrite(const path: string; const data: TBytes; const expected: THash16): Boolean;
var r: TFsResult; o: TOutcome; om: TOnMismatch;
begin
  Result := False;
  if keepCorrupt then om := omKeep else om := omDelete;
  StageEnter(stWrite);
  r := WriteVerified(path, data, expected, om, force, o);
  StageEnter(stNone);
  { in place and whole, but its name may not survive a power cut }
  if r.error = feNotSynced then begin
    Fail(o.path + ': written, but its directory could not be flushed to the disk: ' +
         SysErrorMessage(r.code) + ' (' + r.Text + ')');
    if o.kind = ocKept then Fail(path + ': does not verify; kept as ' + o.path);
    Exit;
  end;
  if not r.Ok then begin
    { the system's own words for its error, and its number }
    if r.code >= 0 then Fail(path + ': could not write it: ' + SysErrorMessage(r.code) + ' (' + r.Text + ')')
    else Fail(path + ': could not write it (' + r.Text + ')');
    Exit;
  end;
  case o.kind of
    ocVerified: Result := True;
    ocDeleted: Fail(path + ': does not verify; nothing written');
    ocKept: Fail(path + ': does not verify; kept as ' + o.path);
  end;
end;

{ Writes data under path, which must verify against `expected`. }
function Save(const path: string; const data: TBytes; const expected: THash16): Boolean;
begin
  Result := SaveCheck(path);
  if Result and not dryRun then Result := SaveWrite(path, data, expected);
end;


function StoredNote(const poa: TBytes): string;
begin
  if (Length(poa) > 5) and ((poa[5] and POA_FLAG_STORED) <> 0) then Result := '  (stored as is)' else Result := '';
end;

{ --stats: where the file's time went (poastage), and its thread (a file
  is coded on one) }
procedure StatsOf;
var t: TStageTimes; st: TStage; o: TInfoNode; line: string; total: Double;
begin
  if not stats then Exit;
  t := StageTimes;
  o := JobNode.Obj('stats');
  line := '';
  total := 0;
  for st := Low(TStage) to High(TStage) do
    if t[st] > 0 then begin
      total := total + t[st];
      o.Fixed(STAGE_NAMES[st] + '_ms', t[st] * 1000, 3);
      if line <> '' then line := line + ', ';
      line := line + STAGE_NAMES[st] + ' ' + DotNumber(t[st] * 1000, 2) + ' ms';
    end;
  o.Fixed('total_ms', total * 1000, 3);
  o.Num('threads', 1);
  { with -q the file's own line is not there: the stats name it }
  if not jsonOut and quiet then CurJob^.outText := CurJob^.outText + CurJob^.name + ':' + LineEnding;
  if not jsonOut then
    CurJob^.outText := CurJob^.outText + '  stats: ' + line + '; total ' + DotNumber(total * 1000, 2) + ' ms; ' +
                       '1 thread(s)' + LineEnding;
end;

{ The committer (PJA 0.9.7's): a file's write, flushed to the disk before
  it takes its name (poafs), waits about 16 ms on a SATA SSD. So when every write is flushed and
  --stats does not time it, the worker checks the name (SaveCheck) and
  hands the write and the rest of the job (its line, its --json object) to
  one thread that does them in turn, and goes on to the next file: the same
  files, lines and order, the flush beside the next file's work. At most
  MAX_PENDING writes wait (their bytes are held). }
type
  TDoneKind = (dkCompress, dkExtract);
  TPending = record
    k: Integer;
    kind: TDoneKind;
    path, f, note: string;
    data: TBytes;
    expected: THash16;
    inLen: Int64;
  end;
  TCommitter = class(TJoinThread)
    procedure Execute; override;
  end;

const
  MAX_PENDING = 8;

var
  asyncCommit: Boolean = False;
  pend: array[0..MAX_PENDING - 1] of TPending;
  pendHead, pendCount: Integer;
  pendStop: Boolean;
  pendLock: TRTLCriticalSection;
  pendWake, pendRoom: PRTLEvent;
  committer: TCommitter = nil;

procedure FinishJob(k: Integer); forward;

{ what a written .poa or original adds to its job }
procedure CompressDone(const f, path: string; origLen: Int64; const poa: TBytes; const note: string);
begin
  CurJob^.outBytes := Length(poa);
  JobNode.Str('output', path);
  JobNode.Num('original_size', origLen);
  JobNode.Num('poa_size', Length(poa));
  { an Ogg file has a page at least: origLen > 0 }
  JobNode.Fixed('ratio_percent', 100 * Length(poa) / origLen);
  JobNode.Bool('stored', StoredNote(poa) <> '');
  if not quiet then
    Say(f + ' -> ' + path + '  ' + Human(origLen) + ' -> ' + Human(Length(poa)) +
        '  ' + DotNumber(100 * Length(poa) / origLen, 2) + '%' +
        { the codec would not have made it smaller }
        StoredNote(poa) + note);
end;

procedure ExtractDone(const f, path: string; const orig: TBytes; poaLen: Int64);
begin
  CurJob^.outBytes := Length(orig);
  JobNode.Str('output', path);
  JobNode.Num('original_size', Length(orig));
  JobNode.Num('poa_size', poaLen);
  if not quiet then Say(f + ' -> ' + path + '  ' + Human(Length(orig)));
end;

{ the job's write and end to the committer; waits while MAX_PENDING wait }
procedure Defer(kind: TDoneKind; const f, path: string; const data: TBytes; const expected: THash16;
  inLen: Int64; const note: string);
var i: Integer;
begin
  CurJob^.deferred := True;
  repeat
    EnterCriticalSection(pendLock);
    if pendCount < MAX_PENDING then begin
      i := (pendHead + pendCount) mod MAX_PENDING;
      pend[i].k := CurJob^.index; pend[i].kind := kind;
      pend[i].f := f; pend[i].path := path; pend[i].note := note;
      pend[i].data := data; pend[i].expected := expected; pend[i].inLen := inLen;
      Inc(pendCount);
      LeaveCriticalSection(pendLock);
      RTLEventSetEvent(pendWake);
      Exit;
    end;
    LeaveCriticalSection(pendLock);
    RTLEventWaitFor(pendRoom, 50);
  until False;
end;

procedure TCommitter.Execute;
var p: TPending; have: Boolean;
begin
  repeat
    EnterCriticalSection(pendLock);
    have := pendCount > 0;
    if have then begin
      p := pend[pendHead];
      pend[pendHead].data := nil;
      pendHead := (pendHead + 1) mod MAX_PENDING;
      Dec(pendCount);
    end;
    LeaveCriticalSection(pendLock);
    if not have then begin
      if pendStop then Break;
      RTLEventWaitFor(pendWake, 50);
      Continue;
    end;
    RTLEventSetEvent(pendRoom);
    CurJob := @jobs[p.k];
    try
      if SaveWrite(p.path, p.data, p.expected) then
        case p.kind of
          dkCompress: CompressDone(p.f, p.path, p.inLen, p.data, p.note);
          dkExtract: ExtractDone(p.f, p.path, p.data, p.inLen);
        end;
    except
      on e: Exception do begin
        if not NotABug(e) then begin
          jobs[p.k].bug := True;
          Fail(jobs[p.k].name + ': internal error: ' + e.ClassName + ': ' + e.Message);
        end else Fail(jobs[p.k].name + ': ' + e.ClassName + ': ' + e.Message);
      end;
    end;
    p.data := nil;
    FinishJob(p.k);
  until False;
end;

procedure StartCommitter;
begin
  InitCriticalSection(pendLock);
  pendWake := RTLEventCreate; pendRoom := RTLEventCreate;
  pendHead := 0; pendCount := 0; pendStop := False;
  try
    committer := TCommitter.Create(False);
  except
    on EThread do committer := nil;
  end;
  asyncCommit := committer <> nil;
end;

{ every write done and every job ended }
procedure StopCommitter;
begin
  if committer = nil then Exit;
  EnterCriticalSection(pendLock);
  pendStop := True;
  LeaveCriticalSection(pendLock);
  RTLEventSetEvent(pendWake);
  committer.Join;
  committer.Free;
  committer := nil;
  asyncCommit := False;
end;

procedure CompressOne(const f: string);
var d, poa: TBytes; r: TPackResult; path: string;
begin
  if not ReadWhole(f, d) then Exit;
  if PoaIsPoa(d) then begin Fail(f + ': already a .poa'); Exit; end;
  r := Pack(d, poa, not noVerify);
  if not r.Ok then begin Fail(f + ': ' + r.Text); Exit; end;
  path := OutputPath(f, AName(f));
  if asyncCommit then begin
    if SaveCheck(path) then Defer(dkCompress, f, path, poa, Blake3_128(poa), Length(d), '');
    Exit;
  end;
  if Save(path, poa, Blake3_128(poa)) then CompressDone(f, path, Length(d), poa, '');
  StatsOf;
end;

procedure ExtractOne(const f: string);
var d, orig: TBytes; r: TPackResult; path: string; h: THash16;
begin
  if not ReadWhole(f, d) then Exit;
  r := Unpack(d, maxOutput, orig, h);
  { a size that does not match is kept only with --keep-corrupt }
  if (r.err = ukSizeMismatch) and (not keepCorrupt or (orig = nil)) then begin Fail(f + ': ' + r.Text); Exit; end;
  if not (r.Ok or (r.err = ukHashMismatch) or (r.err = ukSizeMismatch)) then begin Fail(f + ': ' + r.Text); Exit; end;
  { -n does everything but write: a hash that does not match fails it as
    it fails x (Save, which -n stops before, is where x finds it) }
  if dryRun and (r.err in [ukHashMismatch, ukSizeMismatch]) then begin Fail(f + ': does not verify (' + r.Text + ')'); Exit; end;
  { a size that does not match never verifies, even if its bytes have the
    hash: Save keeps it as NAME.corrupt }
  if r.err = ukSizeMismatch then begin
    h := Blake3_128(orig);
    h[0] := h[0] xor 1;
  end;
  path := OutputPath(f, XName(f));
  { a hash that does not match goes through Save as well: it deletes it, or
    keeps it under another name with --keep-corrupt }
  if asyncCommit then begin
    if SaveCheck(path) then Defer(dkExtract, f, path, orig, h, Length(d), '');
    Exit;
  end;
  if Save(path, orig, h) then ExtractDone(f, path, orig, Length(d));
  StatsOf;
end;

{ t: what x does, without writing: the size and the hash checked }
procedure TestOne(const f: string);
var d, orig: TBytes; r: TPackResult; h: THash16;
begin
  if not ReadWhole(f, d) then Exit;
  if not PoaIsPoa(d) then begin Fail(f + ': FAILED: not a .poa file'); Exit; end;
  r := Unpack(d, maxOutput, orig, h);
  StageEnter(stNone);
  if not r.Ok then begin Fail(f + ': FAILED: ' + r.Text); Exit; end;
  CurJob^.outBytes := Length(orig);
  JobNode.Num('original_size', Length(orig));
  JobNode.Num('poa_size', Length(d));
  if not quiet then Say(f + ': OK  ' + Human(Length(orig)) + ', size and BLAKE3-128 verified');
  StatsOf;
end;

{ info: the structure, and what POA does with it }
procedure InfoOne(const f: string);
var d: TBytes; n, bug: TInfoNode; sl: TStringList;
begin
  if not ReadWhole(f, d) then Exit;
  n := DescribeFile(f, d, False, maxOutput, idDefault);
  bug := n.Find('internal_error');
  if bug <> nil then begin
    CurJob^.bug := True;
    Fail(f + ': internal error: ' + bug.value);
  end;
  if jsonOut then begin
    CurJob^.node.Free;
    CurJob^.node := n;
    Exit;
  end;
  sl := TStringList.Create;
  try
    n.Render(sl, 2);
    sl.Delete(0);
    sl.Insert(0, f);
    Say(TrimRight(sl.Text));
  finally
    sl.Free;
    n.Free;
  end;
end;

procedure ListOne(const f: string);
var d: TBytes; h: TPoaHeader; why, hex, ratio: string;
begin
  if not ReadWhole(f, d) then Exit;
  if not PoaOpen(d, h, why) then begin Fail(f + ': ' + why); Exit; end;
  hex := HexBytes(h.hash);
  JobNode.Num('original_size', h.origSize);
  JobNode.Num('poa_size', Length(d));
  ratio := '';
  if h.origSize > 0 then begin
    JobNode.Fixed('ratio_percent', 100 * Length(d) / h.origSize);
    ratio := ' (' + DotNumber(100 * Length(d) / h.origSize, 2) + '%)';
  end;
  JobNode.Bool('stored', h.stored);
  JobNode.Num('format', h.format);
  JobNode.Str('blake3_128', hex);
  Say(f + '  original ' + IntToStr(h.origSize) + ' B, .poa ' + IntToStr(Length(d)) + ' B' + ratio +
      StoredNote(d) + '  blake3-128 ' + hex);
end;

var
  nextJob, nextPrint: LongInt;
  { the jobs in the order the workers take them }
  order: array of Integer;
  printLock: TRTLCriticalSection;
  { the bytes every file read and wrote, for the summary }
  sumIn, sumOut: Int64;
  { what writing the output met, '' if nothing }
  outputError: string;

{ POA_TEST_CRASH=range or access: a bug on purpose (cli.sh checks how the
  command ends then) }
var crashTarget: PInteger = nil;

procedure CrashTest;
var w: string;
begin
  w := GetEnvironmentVariable('POA_TEST_CRASH');
  if w = 'range' then raise ERangeError.Create('Range check error (POA_TEST_CRASH)');
  if w = 'access' then crashTarget^ := 1;
end;

procedure RunJob(k: Integer);
begin
  CurJob := @jobs[k];
  jobs[k].node := TInfoNode.Create(ikObject);
  jobs[k].node.Str('file', jobs[k].name);
  StageReset;
  try
    { failed before starting: its output is another input's }
    if not jobs[k].failed then begin
      CrashTest;
      case command of
        cmCompress: CompressOne(jobs[k].name);
        cmExtract: ExtractOne(jobs[k].name);
        cmList: ListOne(jobs[k].name);
        cmTest: TestOne(jobs[k].name);
        cmInfo: InfoOne(jobs[k].name);
      end;
    end;
  except
    on e: Exception do begin
      if not NotABug(e) then begin
        jobs[k].bug := True;
        Fail(jobs[k].name + ': internal error: ' + e.ClassName + ': ' + e.Message);
      end else Fail(jobs[k].name + ': ' + e.ClassName + ': ' + e.Message);
    end;
  end;
  { the committer ends it }
  if jobs[k].deferred then Exit;
  FinishJob(k);
end;

{ a job's --json object, and its lines printed when it is next in line }
procedure FinishJob(k: Integer);
begin
  if jsonOut then begin
    { info's "ok": the file was read and described (what POA does with
      it is under "poa") }
    jobs[k].node.Bool('ok', not jobs[k].failed);
    if jobs[k].errors <> '' then jobs[k].node.Str('error', jobs[k].errors);
    if jobs[k].bug and (jobs[k].node.Find('internal_error') = nil) then jobs[k].node.Bool('internal_error', True);
    jobs[k].outText := jobs[k].node.Json + LineEnding;
  end;
  FreeAndNil(jobs[k].node);
  { print every finished job that is next in line }
  EnterCriticalSection(printLock);
  try
    jobs[k].done := True;
    while (nextPrint < Length(jobs)) and jobs[nextPrint].done do begin
      { Output and StdErr are per thread in FPC, each with its own buffer:
        flushed here, inside the lock, or a worker's lines would come out
        when it ends }
      { the output that cannot be written (a full disk) is said once, at
        the end, and the rest of the run goes on without it }
      if (jobs[nextPrint].outText <> '') and (outputError = '') then
        try
          Write(jobs[nextPrint].outText); Flush(Output);
        except
          on e: Exception do begin
            TextRec(Output).BufPos := 0;
            InOutRes := 0;
            outputError := e.Message;
          end;
        end;
      if jobs[nextPrint].errText <> '' then begin Write(StdErr, jobs[nextPrint].errText); Flush(StdErr); end;
      if jobs[nextPrint].failed then Inc(errors);
      if jobs[nextPrint].bug then begin
        if bugs = 0 then bugFile := jobs[nextPrint].name;
        Inc(bugs);
      end;
      Inc(sumIn, jobs[nextPrint].inBytes);
      Inc(sumOut, jobs[nextPrint].outBytes);
      jobs[nextPrint].outText := ''; jobs[nextPrint].errText := '';
      Inc(nextPrint);
    end;
  finally
    LeaveCriticalSection(printLock);
  end;
end;

{ The -th threads are workers, each taking the next file until none is
  left: a file is coded on one thread, so -th parallelises across files
  only. The largest go first (ScheduleJobs). Threads change no output. }
procedure Work;
var k: LongInt;
begin
  repeat
    k := InterLockedIncrement(nextJob) - 1;
    if k >= Length(jobs) then Break;
    RunJob(order[k]);
  until False;
end;

{ With several workers the largest files go first (by the size of the
  input: the original for a, the .poa for x and t), so that no big file is
  left for the end while the other threads wait. A file that cannot be
  read counts as 0 and goes last. The lines still come out in the order of
  the inputs (nextPrint), and with one worker nothing changes. }
procedure ScheduleJobs(workers: Integer);
var i, j, t: Integer; size: array of Int64; sr: TSearchRec;
begin
  order := nil; size := nil;
  SetLength(order, Length(jobs)); SetLength(size, Length(jobs));
  for i := 0 to High(jobs) do begin
    order[i] := i; size[i] := 0;
    if (workers > 1) and (FindFirst(jobs[i].name, faAnyFile, sr) = 0) then begin
      size[i] := sr.Size; FindClose(sr);
    end;
    if size[i] < 0 then size[i] := 0;
    jobs[i].size := size[i];
  end;
  { stable insertion sort, largest first: the same order every run }
  for i := 1 to High(order) do begin
    t := order[i]; j := i - 1;
    while (j >= 0) and (size[order[j]] < size[t]) do begin order[j + 1] := order[j]; Dec(j); end;
    order[j + 1] := t;
  end;
end;

type
  TWorker = class(TJoinThread)
    procedure Execute; override;
  end;

procedure TWorker.Execute;
begin
  Work;
end;

{ the end of a run that met a bug: what to do about it }
procedure BugNote(const f: string);
var name: string;
begin
  name := f;
  if name = '' then name := 'FILE';
  if Pos(' ', name) > 0 then name := '"' + name + '"';
  Writeln(StdErr, 'poa: This is a bug in POA. Please run: poa report ', name, ' and open an issue at ', ISSUES_URL);
end;

{ poa report }
function DoReport: Integer;
var d: TBytes; f, title, text, url, copied, msg, dir: string; job: TFileJob; rest: array of string; i: Integer;
    r: TFsResult; o: TOutcome; tb: TBytes; cut: Boolean;
begin
  Result := 0;
  f := '';
  d := nil;
  job := Default(TFileJob);
  CurJob := @job;
  if inputs.Count > 0 then begin
    f := inputs[0];
    if not ReadWhole(f, d) then begin Write(StdErr, job.errText); Exit(1); end;
  end;
  rest := nil;
  SetLength(rest, ArgCount);
  for i := 1 to ArgCount do rest[i - 1] := args[i];
  text := BuildReport(f, d, rest, threads, maxOutput, title);
  url := IssueUrl(title, text, cut);
  if outArg = '' then Write(text)
  else begin
    tb := nil;
    SetLength(tb, Length(text));
    if Length(text) > 0 then Move(text[1], tb[0], Length(text));
    r := WriteVerified(outArg, tb, Blake3_128(tb), omDelete, force, o);
    { whole and in place, but its name may not survive a power cut }
    if r.error = feNotSynced then begin
      Writeln(StdErr, 'poa: ', outArg, ': written, but its directory could not be flushed to the disk: ',
              SysErrorMessage(r.code), ' (', r.Text, ')');
      Exit(1);
    end;
    if not r.Ok then begin
      if r.code >= 0 then Writeln(StdErr, 'poa: ', outArg, ': could not write it: ', SysErrorMessage(r.code), ' (', r.Text, ')')
      else Writeln(StdErr, 'poa: ', outArg, ': could not write it (', r.Text, ')');
      Exit(1);
    end;
    Writeln('poa: the report is in ', outArg);
  end;
  if withFile and (f <> '') then begin
    if outArg <> '' then dir := ExtractFilePath(outArg) else dir := '';
    copied := CopyBeside(f, d, dir, msg);
    if copied = '' then begin Writeln(StdErr, 'poa: ', msg); Result := 1; end
    else Writeln('poa: the file, to attach if you wish: ', copied,
                 ' (GitHub does not take Ogg files: zip it first)');
  end;
  Writeln;
  if cut then
    Writeln('Open an issue with this report (the link has room for part of it: paste the whole report ',
            'in the issue, check it and add the steps):')
  else Writeln('Open an issue with this report (the link holds it; check it and add the steps):');
  Writeln(url);
end;

{ the summary of --stats and --json }
procedure Summary(wall: Double);
var o, s: TInfoNode; orig: Int64;
begin
  if jsonOut then begin
    o := TInfoNode.Create(ikObject);
    try
      s := o.Obj('summary');
      s.Str('command', args[CommandIndex]);
      s.Num('files', Length(jobs));
      s.Num('failed', errors);
      s.Num('bugs', bugs);
      s.Num('bytes_in', sumIn);
      s.Num('bytes_out', sumOut);
      s.Fixed('seconds', wall, 6);
      s.Num('threads', threads);
      Writeln(o.Json);
    finally
      o.Free;
    end;
  end else if stats then begin
    { MB/s of the originals: what a reads, what x and t give }
    if command = cmCompress then orig := sumIn else orig := sumOut;
    Write('poa: ', Length(jobs), ' file(s), ', Human(sumIn), ' -> ', Human(sumOut), ', ',
          DotNumber(wall * 1000, 2), ' ms, ', threads, ' thread(s)');
    if wall > 0 then Write(', ', DotNumber(orig / (1024 * 1024) / wall, 2), ' MB/s');
    Writeln;
  end;
end;

var i, n, workers: Integer; pool: array of TWorker; path: string; started: Double;
begin
  { On Unix only '/' separates: the RTL's ExtractFileName and ChangeFileExt
    also cut at '\', a plain character there, so 'a\x.ogg' and 'b\x.ogg'
    would both go to x.ogg.poa. }
  {$ifndef MSWINDOWS} AllowDirectorySeparators := ['/']; {$endif}
  { the commit, from POA_COMMIT at build time ('' if not set): here, in
    the program, which is compiled every time }
  BuildCommit := {$I %POA_COMMIT%};
  BuildDate := {$I %DATE%};
  { POA_TRACE=1: the coder's trace on stderr (poaside) }
  poaside.Trace := GetEnvironmentVariable('POA_TRACE') <> '';
  errors := 0; bugs := 0; bugFile := ''; sumIn := 0; sumOut := 0; outputError := '';
  try
  ParseArgs;
  { before any write: report's and bench's too }
  InstallInterruptCleanup;
  ApplyCpu;
  StagesOn := stats;
  case command of
    cmReport: Finish(DoReport);
    cmBench: Finish(RunBench(inputs, runs, threads));
    { --cpu: that path alone }
    cmSelftest: Finish(RunSelftest(quiet, cpuGiven, cpuWanted));
  end;
  started := Seconds;
  if (outArg <> '') and (inputs.Count > 1) and not (DirectoryExists(outArg) or EndsWithSeparator(outArg)) then
    UsageError('-o with several inputs has to be a directory');
  jobs := nil;
  SetLength(jobs, inputs.Count);
  InitCriticalSection(claimLock);
  outKeys := NewKeyList; inKeys := NewKeyList;
  for i := 0 to inputs.Count - 1 do begin
    jobs[i] := Default(TFileJob);
    jobs[i].name := inputs[i];
    jobs[i].index := i;
    inKeys.AddObject(PathKey(inputs[i]), TObject(PtrInt(i)));
  end;
  { the outputs of a and x follow from the names alone (a .poa keeps no
    name): taken here, in the order of the inputs, so it is always the later
    one that fails. An input that is not there takes nothing: it fails on
    its own, and must not take a later one down. }
  if command in [cmCompress, cmExtract] then
    for i := 0 to High(jobs) do if FileExists(jobs[i].name) then begin
      CurJob := @jobs[i];
      if command = cmCompress then path := OutputPath(jobs[i].name, AName(jobs[i].name))
      else path := OutputPath(jobs[i].name, XName(jobs[i].name));
      Claim(path);
    end;
  { one file a worker at a time }
  workers := threads;
  if workers > inputs.Count then workers := inputs.Count;
  nextJob := 0; nextPrint := 0;
  ScheduleJobs(workers);
  InitCriticalSection(printLock);
  { the writes beside the work: when each is flushed, and --stats does not
    time them }
  if (command in [cmCompress, cmExtract]) and SyncToDisk and not dryRun and not stats and
     (GetEnvironmentVariable('POA_SYNC_INLINE') = '') then StartCommitter;
  pool := nil;
  SetLength(pool, workers - 1);
  { a thread the system refuses (a host at its limit) leaves the files to
    the ones it gave and to this one: the same outputs, only slower }
  n := 0;
  while n < Length(pool) do begin
    try
      pool[n] := TWorker.Create(False);
    except
      on EThread do Break;
    end;
    Inc(n);
  end;
  SetLength(pool, n);
  Work;
  for i := 0 to High(pool) do begin pool[i].Join; pool[i].Free; end;
  StopCommitter;
  DoneCriticalSection(printLock);
  DoneCriticalSection(claimLock);
  if (stats or jsonOut) and (outputError = '') then Summary(Seconds - started);
  if outputError <> '' then begin
    Writeln(StdErr, 'poa: could not write the output: ', outputError);
    if bugs > 0 then begin BugNote(bugFile); Halt(3); end;
    Halt(1);
  end;
  if errors > 0 then begin
    if inputs.Count > 1 then Writeln(StdErr, 'poa: ', errors, ' of ', inputs.Count, ' files failed');
    if bugs > 0 then begin BugNote(bugFile); Halt(3); end;
    Halt(1);
  end;
  Finish(0);
  except
    { anything not caught where a file is worked on: a bug }
    on e: Exception do begin
      { a write or a read the system refused (a full disk): not a bug }
      if NotABug(e) then begin
        if e is EInOutError then OutputFailed(e.Message) else Writeln(StdErr, 'poa: ', e.Message);
        Halt(1);
      end;
      Writeln(StdErr, 'poa: internal error: ', e.ClassName, ': ', e.Message);
      if inputs <> nil then begin
        if inputs.Count > 0 then BugNote(inputs[0]) else BugNote('');
      end else BugNote('');
      Halt(3);
    end;
  end;
end.
