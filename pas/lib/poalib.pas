{ libpoa: POA as a shared library with a C interface (poa.h), for archivers
  and other programs. Ported from PPA's pas/lib/ppalib.pas (itself shaped
  as PJA's libpja).

    pas/lib/build.sh <out dir>   -> poa.so / poa.dll / poa.dylib

  poa_compress and poa_decompress are poaformat's PoaEncode (verified by
  decoding it back) and PoaDecode: a .poa. The filter is C (poafilter.c),
  and calls back here for memory and for the codec on each Ogg file it
  finds. The same file is a 7-Zip / 7-Zip-zstd plugin: the functions 7-Zip
  looks for (GetNumberOfMethods, GetMethodProperty, CreateDecoder,
  CreateEncoder, CreateObject, GetModuleProp) are poa7z.c's, exported from
  here.

  No exception leaves the library: every export catches them and returns
  an error code. }
library poa;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}{$ifdef windows}poaheap,{$endif}
  Classes, SysUtils, poacpu, poaformat, poasysinfo, pjamodel;

{$L poafilter.o}
{$L poa7z.o}

const
  POA_OK = 0;
  POA_E_NOT_TAKEN = 1;
  POA_E_DATA = 2;
  POA_E_MEMORY = 3;
  POA_E_ARG = 6;
  POA_E_VERSION = 7;
  { poa_decompress's own cap on an original's size }
  MAX_ORIGINAL = QWord(1) shl 31;
  VERSION_TEXT: PChar = 'poa ' + POA_VERSION;

type
  {$packrecords c}
  { poafilter.c's job_t: a file to compress, or a stream to decompress }
  TJob = record
    input: PByte;
    size, expected: SizeUInt;
    output: PByte;
    outSize: SizeUInt;
    ok, threads: LongInt;
    done: LongInt;
    { decoding, not ok: 1 when the stream is of a later version
      (POA_E_VERSION), 2 when there was no memory for it (POA_E_MEMORY) }
    cause: LongInt;
  end;
  PJob = ^TJob;
  { poafilter.c's host_t }
  THost = record
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    poolOpen: function(threads, packing: LongInt): Pointer; cdecl;
    poolSubmit: procedure(pool: Pointer; job: PJob); cdecl;
    poolWait: procedure(pool: Pointer; job: PJob); cdecl;
    poolClose: procedure(pool: Pointer); cdecl;
  end;
  {$packrecords default}
  TReadFn = function(ctx, buf: Pointer; size: SizeUInt): PtrInt; cdecl;
  TWriteFn = function(ctx: Pointer; buf: Pointer; size: SizeUInt): LongInt; cdecl;

procedure poafilter_host(constref h: THost); cdecl; external;
function poafilter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;
function poafilter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
  threads: LongInt): LongInt; cdecl; external;

type
  { poa7z.c's host7z_t }
  THost7z = record
    bstr: function(bytes: Pointer; len: LongWord): Pointer; cdecl;
    alloc: function(size: SizeUInt): Pointer; cdecl;
    release: procedure(p: Pointer); cdecl;
    threads: LongInt;
  end;
  { 7-Zip's calling convention for its exports and interfaces }
  HRESULT = LongInt;

procedure poa7z_host(constref h: THost7z); cdecl; external;
function poa7z_GetNumberOfMethods(n: PLongWord): HRESULT; cdecl; external;
function poa7z_GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; cdecl; external;
function poa7z_CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function poa7z_CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function poa7z_CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; cdecl; external;
function poa7z_GetModuleProp(prop: LongWord; v: Pointer): HRESULT; cdecl; external;

{$ifdef windows}
function SysAllocStringByteLen(s: Pointer; len: LongWord): Pointer; stdcall; external 'oleaut32.dll';

function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
begin
  Result := SysAllocStringByteLen(bytes, len);
end;
{$else}
function malloc(size: SizeUInt): Pointer; cdecl; external 'c';

{ 7-Zip's BSTR outside Windows (CPP/Common/MyWindows.cpp): from malloc, a
  32-bit byte count, the bytes, and two zero bytes; 7-Zip frees it }
function MakeBstr(bytes: Pointer; len: LongWord): Pointer; cdecl;
var p: PByte;
begin
  p := malloc(SizeUInt(len) + 4 + 4);
  if p = nil then Exit(nil);
  PLongWord(p)^ := len;
  Result := p + 4;
  if len > 0 then Move(bytes^, Result^, len);
  FillChar((p + 4 + len)^, 4, 0);
end;
{$endif}

function HostAlloc(size: SizeUInt): Pointer; cdecl;
begin
  try
    Result := GetMem(size);
  except
    Result := nil;
  end;
end;

procedure HostRelease(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

{ bytes -> a fresh buffer for the caller, nil when there is no memory; one
  byte more, so that an empty result is not a null pointer }
function Hand(const b: TBytes; out output: PByte; out outSize: SizeUInt): Boolean;
begin
  outSize := Length(b);
  output := HostAlloc(outSize + 1);
  Result := output <> nil;
  if Result and (outSize > 0) then Move(b[0], output^, outSize);
end;

function InBytes(input: PByte; size: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, size);
  if size > 0 then Move(input^, Result[0], size);
end;

{ PJA's codec (the covers' JPEGs) keeps its models in threadvars, about
  18 MB, which nothing frees when a host's thread ends: given back at the
  end of every call that may have used them (as PPA's libppa does) }
procedure GiveBackModels;
begin
  try
    ReleaseThreadModels;
  except
  end;
end;

{ a caller's thread count: 1 to 64, as the 7-Zip plugin takes them; the
  filter keeps 8 jobs a thread, and a count past that would overflow }
function Threads1to64(threads: LongInt): LongInt;
begin
  if threads < 1 then Result := 1
  else if threads > 64 then Result := 64
  else Result := threads;
end;

{ POA's .poa of a, verified: decoded back and compared. False when POA
  does not take it (not Ogg) or does not make it smaller. }
function EncodeVerified(const a: TBytes; out c: TBytes): Boolean;
var st: TPoaStats; back: TBytes;
begin
  Result := False;
  c := PoaEncode(a, st);
  if (st.Pages = 0) or (Length(c) >= Length(a)) or (c[5] and POA_FLAG_STORED <> 0) then Exit;
  back := PoaDecode(c);
  Result := (Length(back) = Length(a)) and ((Length(a) = 0) or CompareMem(@back[0], @a[0], Length(a)));
end;

{ one of the filter's jobs. Encoding: the Ogg file as a .poa, not ok when
  POA does not take it. Decoding: the file back, of `expected` bytes. }
procedure RunJob(var j: TJob; packing: Boolean; threads: Integer);
var b: TBytes; c: TBytes;
begin
  j.output := nil; j.outSize := 0; j.ok := 0; j.cause := 0;
  try
    if packing then begin
      if not EncodeVerified(InBytes(j.input, j.size), b) then Exit;
    end else begin
      c := InBytes(j.input, j.size);
      if PoaIsPoa(c) and (c[4] > POA_FORMAT) then begin j.cause := 1; Exit; end;
      try
        b := PoaDecode(c);
      except
        on EPoaFormat do Exit;
      end;
      if QWord(Length(b)) <> QWord(j.expected) then Exit;
    end;
    if Hand(b, j.output, j.outSize) then j.ok := 1
    else if not packing then j.cause := 2;
  except
    on EOutOfMemory do begin
      if j.output <> nil then FreeMem(j.output);
      j.output := nil; j.ok := 0;
      if not packing then j.cause := 2;
    end;
    else begin
      if j.output <> nil then FreeMem(j.output);
      j.output := nil; j.ok := 0;
    end;
  end;
end;

type
  { the filter's pool: threads that take the jobs in the order they come
    and run them; the filter waits for each one in its own order }
  TPool = class;
  TPoolThread = class(TThread)
    pool: TPool;
    procedure Execute; override;
  end;
  TPool = class
    lock: TRTLCriticalSection;
    work, finished: PRTLEvent;
    queue: array of PJob;
    head, count: Integer;
    stop, packing: Boolean;
    workers: array of TPoolThread;
    function Take(out j: PJob): Boolean;
  end;

{ the next job, or nil; False when the pool is closing and nothing is left }
function TPool.Take(out j: PJob): Boolean;
begin
  EnterCriticalSection(lock);
  j := nil;
  if head < count then begin j := queue[head]; Inc(head); end;
  if head = count then begin head := 0; count := 0; end;
  Result := (j <> nil) or not stop;
  LeaveCriticalSection(lock);
end;

procedure TPoolThread.Execute;
var j: PJob;
begin
  while pool.Take(j) do
    if j = nil then RTLEventWaitFor(pool.work, 20)
    else begin
      RunJob(j^, pool.packing, j^.threads);
      InterLockedExchange(j^.done, 1);
      RTLEventSetEvent(pool.finished);
    end;
  GiveBackModels;
end;

function OpenPool(threads, packing: LongInt): Pointer; cdecl;
var p: TPool; k: Integer;
begin
  Result := nil;
  p := nil;
  try
    threads := Threads1to64(threads);
    p := TPool.Create;
    InitCriticalSection(p.lock);
    p.work := RTLEventCreate;
    p.finished := RTLEventCreate;
    p.packing := packing <> 0;
    SetLength(p.queue, 64);
    SetLength(p.workers, threads);
    { a thread the system refuses (a host at its limit): the pool goes on
      with the ones it gave; with none, the failure below }
    for k := 0 to threads - 1 do begin
      try
        p.workers[k] := TPoolThread.Create(True);
      except
        on EThread do begin
          if k = 0 then raise;
          SetLength(p.workers, k);
          Break;
        end;
      end;
      p.workers[k].pool := p;
      p.workers[k].Start;
    end;
    Result := p;
  except
    { the workers started before the failure: stopped and freed, or they
      would wait on a pool nobody holds }
    if p <> nil then begin
      p.stop := True;
      for k := 0 to High(p.workers) do
        if p.workers[k] <> nil then begin
          RTLEventSetEvent(p.work);
          if not p.workers[k].Suspended then p.workers[k].WaitFor;
          p.workers[k].Free;
        end;
    end;
    Result := nil;
  end;
end;

procedure SubmitJob(pool: Pointer; job: PJob); cdecl;
var p: TPool;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  if p.count = Length(p.queue) then SetLength(p.queue, 2 * Length(p.queue));
  p.queue[p.count] := job;
  Inc(p.count);
  LeaveCriticalSection(p.lock);
  RTLEventSetEvent(p.work);
end;

procedure WaitJob(pool: Pointer; job: PJob); cdecl;
begin
  while InterLockedCompareExchange(job^.done, 1, 1) = 0 do
    RTLEventWaitFor(TPool(pool).finished, 20);
end;

procedure ClosePool(pool: Pointer); cdecl;
var p: TPool; k: Integer;
begin
  p := TPool(pool);
  EnterCriticalSection(p.lock);
  p.stop := True;
  LeaveCriticalSection(p.lock);
  for k := 0 to High(p.workers) do begin
    RTLEventSetEvent(p.work);
    p.workers[k].WaitFor;
    p.workers[k].Free;
  end;
  RTLEventDestroy(p.work);
  RTLEventDestroy(p.finished);
  DoneCriticalSection(p.lock);
  p.Free;
end;

function poa_version: PChar; cdecl;
begin
  Result := VERSION_TEXT;
end;

{ poa_compress and poa_decompress run the codec on the caller's thread.
  out and outSize are pointers, not out parameters, so that a null one is
  an error and not a crash. }
function poa_compress(input: PByte; size: SizeUInt; output: PPByte; outSize: PSizeUInt;
                      threads: LongInt): LongInt; cdecl;
var c: TBytes;
begin
  if (output = nil) or (outSize = nil) then Exit(POA_E_ARG);
  output^ := nil; outSize^ := 0;
  if (input = nil) and (size > 0) then Exit(POA_E_ARG);
  try
    { not Ogg, empty, not made smaller, or (a bug) not given back: the
      caller keeps the bytes its own way }
    try
      if not EncodeVerified(InBytes(input, size), c) then Exit(POA_E_NOT_TAKEN);
      if Hand(c, output^, outSize^) then Result := POA_OK else Result := POA_E_MEMORY;
    finally
      GiveBackModels;
    end;
  except
    on EPoaFormat do Result := POA_E_NOT_TAKEN;
    else Result := POA_E_MEMORY;
  end;
end;

function poa_decompress(input: PByte; size: SizeUInt; output: PPByte; outSize: PSizeUInt;
                        maxSize: SizeUInt; threads: LongInt): LongInt; cdecl;
var c, original: TBytes; cap, declared: QWord; i: Integer;
begin
  if (output = nil) or (outSize = nil) then Exit(POA_E_ARG);
  output^ := nil; outSize^ := 0;
  if (input = nil) and (size > 0) then Exit(POA_E_ARG);
  cap := MAX_ORIGINAL;
  if (maxSize > 0) and (maxSize < cap) then cap := maxSize;
  try
    c := InBytes(input, size);
    if not PoaIsPoa(c) then Exit(POA_E_DATA);
    if c[4] > POA_FORMAT then Exit(POA_E_VERSION);
    declared := 0;
    for i := 7 downto 0 do declared := (declared shl 8) or c[6 + i];
    if declared > cap then Exit(POA_E_MEMORY);
    try
      try
        original := PoaDecode(c);
      except
        on EPoaFormat do Exit(POA_E_DATA);
      end;
    finally
      GiveBackModels;
    end;
    if Hand(original, output^, outSize^) then Result := POA_OK else Result := POA_E_MEMORY;
  except
    Result := POA_E_MEMORY;
  end;
end;

procedure poa_free(p: Pointer); cdecl;
begin
  FreeMem(p);
end;

function poa_filter_encode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := poafilter_encode(read, readCtx, write, writeCtx, Threads1to64(threads));
  except
    Result := POA_E_MEMORY;
  end;
end;

function poa_filter_decode(read: TReadFn; readCtx: Pointer; write: TWriteFn; writeCtx: Pointer;
                           threads: LongInt): LongInt; cdecl;
begin
  try
    Result := poafilter_decode(read, readCtx, write, writeCtx, Threads1to64(threads));
  except
    Result := POA_E_MEMORY;
  end;
end;

{ the 7-Zip plugin's exports: STDAPI, __stdcall on Windows x86 }
function GetNumberOfMethods(n: PLongWord): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_GetNumberOfMethods(n);
end;

function GetMethodProperty(index, prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_GetMethodProperty(index, prop, v);
end;

function CreateDecoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_CreateDecoder(index, iid, obj);
end;

function CreateEncoder(index: LongWord; iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_CreateEncoder(index, iid, obj);
end;

function CreateObject(clsid, iid: Pointer; out obj: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_CreateObject(clsid, iid, obj);
end;

function GetModuleProp(prop: LongWord; v: Pointer): HRESULT; {$ifdef windows}stdcall{$else}cdecl{$endif};
begin
  Result := poa7z_GetModuleProp(prop, v);
end;

var host: THost; host7z: THost7z;

exports
  poa_version, poa_compress, poa_decompress, poa_free, poa_filter_encode, poa_filter_decode,
  GetNumberOfMethods, GetMethodProperty, CreateDecoder, CreateEncoder, CreateObject, GetModuleProp;

begin
  IsMultiThread := True;
  host.alloc := @HostAlloc;
  host.release := @HostRelease;
  host.poolOpen := @OpenPool;
  host.poolSubmit := @SubmitJob;
  host.poolWait := @WaitJob;
  host.poolClose := @ClosePool;
  poafilter_host(host);
  host7z.bstr := @MakeBstr;
  host7z.alloc := @HostAlloc;
  host7z.release := @HostRelease;
  { 7-Zip on 32 bits: fewer, each file's model takes about 60 MB }
  host7z.threads := CpuCount;
  if host7z.threads > 8 then host7z.threads := 8;
  if (SizeOf(Pointer) = 4) and (host7z.threads > 2) then host7z.threads := 2;
  poa7z_host(host7z);
end.
