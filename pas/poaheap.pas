{ From PJA (pas/pjaheap.pas), the same code under another name.

  The libraries' memory on Windows: the process heap (HeapAlloc) in place
  of FreePascal's own heap. First in a library's uses, so that it is in
  place before the other units take memory.

  Why: FreePascal 3.2.2's heap, in a DLL, counts the threads that use it
  and deletes its lock (heap_lock) when the count comes back to zero. The
  thread that loads the DLL is the first in that count, and if it ends
  while the DLL stays loaded the count can reach zero: the lock is gone,
  and the next block freed by a thread other than the one that took it
  (every new thread frees one: its start record) enters a deleted
  critical section. 7-Zip's file manager (7zFM) loads its codecs from such
  a short-lived thread, and crashed in PJA's threads (PJA, which found it) on testing or
  extracting from inside an archive (7z.exe and 7zG, which load them from
  their main thread, did not).

  Each block carries 16 bytes before it, its size and a mark, so that
  blocks stay aligned as the process heap gives them (16 bytes on x64, 8 on
  x86) and a block the runtime took before this unit started is told apart
  and given back to the manager that took it.

  And 16 bytes after it, never used: FreePascal reads a little past the
  end of an array where that is harmless with its own heap, whose blocks
  always have room after them (on i386, `w[i] and $1F` of an array of Word
  loads 4 bytes for the last element's 2). The process heap can end a
  block where its memory ends, and Windows XP's often did: an access
  violation once in a while, which a 32-bit 7-Zip on XP showed as a data
  error (found testing 0.1.1 on 07/11/2026). }
unit poaheap;

{$mode objfpc}

interface

implementation

{$ifdef windows}
const
  HEAP_ZERO_MEMORY = 8;
  HEAD_BYTES = 16;
  TAIL_BYTES = 16;
  OURS = PtrUInt({$ifdef cpu64}$9E3779B97F4A7C15{$else}$9E3779B9{$endif});

type
  PHeader = ^THeader;
  THeader = record
    size, mark: PtrUInt;
  end;

function GetProcessHeap: THandle; stdcall; external 'kernel32' name 'GetProcessHeap';
function HeapAlloc(heap: THandle; flags: LongWord; size: PtrUInt): Pointer; stdcall;
  external 'kernel32' name 'HeapAlloc';
function HeapReAlloc(heap: THandle; flags: LongWord; p: Pointer; size: PtrUInt): Pointer; stdcall;
  external 'kernel32' name 'HeapReAlloc';
function HeapFree(heap: THandle; flags: LongWord; p: Pointer): LongBool; stdcall;
  external 'kernel32' name 'HeapFree';

var
  heap: THandle;
  old: TMemoryManager;

function Mine(p: Pointer): Boolean; inline;
begin
  Result := PHeader(p - HEAD_BYTES)^.mark = OURS;
end;

{ no memory: nil. The runtime's callers make that EOutOfMemory, which the
  libraries' exports catch, with nothing more to allocate; a runtime error
  raised from here instead needs memory for its exception, fails again and
  ends the host (measured on Windows x86 with 2 MB left: nil gives
  POA_E_MEMORY, as FreePascal's own heap does) }
function Fail: Pointer;
begin
  Result := nil;
end;

function Take(size: PtrUInt; flags: LongWord): Pointer;
var h: PHeader;
begin
  if size > High(PtrUInt) - HEAD_BYTES - TAIL_BYTES then Exit(Fail);
  h := HeapAlloc(heap, flags, size + HEAD_BYTES + TAIL_BYTES);
  if h = nil then Exit(Fail);
  h^.size := size;
  h^.mark := OURS;
  Result := Pointer(h) + HEAD_BYTES;
end;

function HGetMem(size: PtrUInt): Pointer;
begin
  Result := Take(size, 0);
end;

function HAllocMem(size: PtrUInt): Pointer;
begin
  Result := Take(size, HEAP_ZERO_MEMORY);
end;

function HFreeMem(p: Pointer): PtrUInt;
begin
  if p = nil then Exit(0);
  if not Mine(p) then Exit(old.FreeMem(p));
  Result := PHeader(p - HEAD_BYTES)^.size;
  PHeader(p - HEAD_BYTES)^.mark := 0;
  HeapFree(heap, 0, p - HEAD_BYTES);
end;

function HFreeMemSize(p: Pointer; size: PtrUInt): PtrUInt;
begin
  Result := HFreeMem(p);
end;

function HMemSize(p: Pointer): PtrUInt;
begin
  if not Mine(p) then Exit(old.MemSize(p));
  Result := PHeader(p - HEAD_BYTES)^.size;
end;

function HReAllocMem(var p: Pointer; size: PtrUInt): Pointer;
var h: PHeader; q: Pointer; n: PtrUInt;
begin
  if size = 0 then begin
    HFreeMem(p);
    p := nil;
  end else if p = nil then
    p := HGetMem(size)
  else if Mine(p) then begin
    if size > High(PtrUInt) - HEAD_BYTES - TAIL_BYTES then Exit(Fail);
    h := HeapReAlloc(heap, 0, p - HEAD_BYTES, size + HEAD_BYTES + TAIL_BYTES);
    if h = nil then Exit(Fail);
    h^.size := size;
    p := Pointer(h) + HEAD_BYTES;
  end else begin
    q := HGetMem(size);
    if q = nil then Exit(nil);
    n := old.MemSize(p);
    if n > size then n := size;
    Move(p^, q^, n);
    old.FreeMem(p);
    p := q;
  end;
  Result := p;
end;

function HGetHeapStatus: THeapStatus;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function HGetFPCHeapStatus: TFPCHeapStatus;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

var
  mm: TMemoryManager;

initialization
  heap := GetProcessHeap;
  GetMemoryManager(old);
  mm := old;
  mm.NeedLock := False;
  mm.GetMem := @HGetMem;
  mm.FreeMem := @HFreeMem;
  mm.FreeMemSize := @HFreeMemSize;
  mm.AllocMem := @HAllocMem;
  mm.ReAllocMem := @HReAllocMem;
  mm.MemSize := @HMemSize;
  mm.GetHeapStatus := @HGetHeapStatus;
  mm.GetFPCHeapStatus := @HGetFPCHeapStatus;
  SetMemoryManager(mm);
{$endif}
end.
