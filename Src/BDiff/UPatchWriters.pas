{
 * UPatchWriters.pas
 *
 * Heirachy of classes used to write various types of patch, along with factory
 * class.
 *
 * Patch generation code based portions of bdiff.c by Stefan Reuther, copyright
 * (c) 1999 Stefan Reuther <Streu@gmx.de>.
 *
 * Copyright (c) 2011 Peter D Johnson (www.delphidabbler.com).
 *
 * $Rev$
 * $Date$
 *
 * THIS SOFTWARE IS PROVIDED "AS-IS", WITHOUT ANY EXPRESS OR IMPLIED WARRANTY.
 * IN NO EVENT WILL THE AUTHORS BE HELD LIABLE FOR ANY DAMAGES ARISING FROM THE
 * USE OF THIS SOFTWARE.
 *
 * For conditions of distribution and use see the LICENSE file of visit
 * http://www.delphidabbler.com/software/bdiff/license
}


unit UPatchWriters;

interface

uses
  // Project
  UBDiffTypes;

type

  TPatchWriter = class(TObject)
  public
    procedure Header(const OldFileName, NewFileName: string;
      const OldFileSize, NewFileSize: size_t); virtual; abstract;
    procedure Add(Data: PSignedAnsiChar; Length: size_t); virtual; abstract;
    procedure Copy(NewBuf: PSignedAnsiCharArray; NewPos: size_t;
      OldPos: size_t; Length: size_t); virtual; abstract;
  end;

  TPatchWriterFactory = class(TObject)
  public
    class function Instance(const Format: TFormat): TPatchWriter;
  end;

implementation

uses
  // Delphi
  SysUtils,
  // Project
  UBDiffUtils, UUtils;

type
  TBinaryPatchWriter = class(TPatchWriter)
  private
    procedure PackLong(P: PSignedAnsiChar; L: Longint);
    function CheckSum(Data: PSignedAnsiChar; Length: size_t): Longint;
  public
    procedure Header(const OldFileName, NewFileName: string;
      const OldFileSize, NewFileSize: size_t); override;
    procedure Add(Data: PSignedAnsiChar; Length: size_t); override;
    procedure Copy(NewBuf: PSignedAnsiCharArray; NewPos: size_t;
      OldPos: size_t; Length: size_t); override;
  end;

  TTextPatchWriter = class(TPatchWriter)
  protected
    procedure CopyHeader(NewPos: size_t; OldPos: size_t; Length: size_t);
    procedure Header(const OldFileName, NewFileName: string;
      const OldFileSize, NewFileSize: size_t); override;
  end;

  TQuotedPatchWriter = class(TTextPatchWriter)
  private
    procedure QuotedData(Data: PSignedAnsiChar; Length: size_t);
  public
    procedure Add(Data: PSignedAnsiChar; Length: size_t); override;
    procedure Copy(NewBuf: PSignedAnsiCharArray; NewPos: size_t;
      OldPos: size_t; Length: size_t); override;
  end;

  TFilteredPatchWriter = class(TTextPatchWriter)
  private
    procedure FilteredData(Data: PSignedAnsiChar; Length: size_t);
  public
    procedure Add(Data: PSignedAnsiChar; Length: size_t); override;
    procedure Copy(NewBuf: PSignedAnsiCharArray; NewPos: size_t;
      OldPos: size_t; Length: size_t); override;
  end;

{ TPatchWriterFactory }

class function TPatchWriterFactory.Instance(
  const Format: TFormat): TPatchWriter;
begin
  case Format of
    FMT_BINARY: Result := TBinaryPatchWriter.Create;
    FMT_FILTERED: Result := TFilteredPatchWriter.Create;
    FMT_QUOTED: Result := TQuotedPatchWriter.Create;
    else raise Exception.Create('Invalid format type');
  end;
end;

{ TBinaryPatchWriter }

procedure TBinaryPatchWriter.Add(Data: PSignedAnsiChar; Length: size_t);
var
  Rec: packed record
    DataLength: array[0..3] of SignedAnsiChar;  // length of added adata
  end;
const
  cPlusSign: AnsiChar = '+';                // flags added data
begin
  WriteStr(StdOut, cPlusSign);
  PackLong(@Rec.DataLength, Length);
  WriteBin(StdOut, @Rec, SizeOf(Rec));
  WriteBin(StdOut, Data, Length);           // data added
end;

{ Compute simple checksum }
function TBinaryPatchWriter.CheckSum(Data: PSignedAnsiChar;
  Length: size_t): Longint;
begin
  Result := 0;
  while Length <> 0 do
  begin
    Dec(Length);
    Result := ((Result shr 30) and 3) or (Result shl 2);
    Result := Result xor Ord(Data^);
    Inc(Data);
  end;
end;

procedure TBinaryPatchWriter.Copy(NewBuf: PSignedAnsiCharArray; NewPos, OldPos,
  Length: size_t);
var
  Rec: packed record
    CopyStart: array[0..3] of SignedAnsiChar;   // starting pos of copied data
    CopyLength: array[0..3] of SignedAnsiChar;  // length copied data
    CheckSum: array[0..3] of SignedAnsiChar;    // validates copied data
  end;
const
  cAtSign: AnsiChar = '@';                  // flags command data in both file
begin
  WriteStr(StdOut, cAtSign);
  PackLong(@Rec.CopyStart, OldPos);
  PackLong(@Rec.CopyLength, Length);
  PackLong( @Rec.CheckSum, CheckSum(@NewBuf[NewPos], Length));
  WriteBin(StdOut, @Rec, SizeOf(Rec));
end;

procedure TBinaryPatchWriter.Header(const OldFileName, NewFileName: string;
  const OldFileSize, NewFileSize: size_t);
var
  Head: packed record
    Signature: array[0..7] of SignedAnsiChar;     // file signature
    OldDataSize: array[0..3] of SignedAnsiChar;   // size of old data file
    NewDataSize: array[0..3] of SignedAnsiChar;   // size of new data file
  end;
const
  // File signature. Must be 8 bytes. Format is 'bdiff' + file-version + #$1A
  // where file-version is a two char string, here '02'.
  // If file format is changed then increment the file version
  cFileSignature: array[0..7] of AnsiChar = 'bdiff02'#$1A;
begin
  Assert(Length(cFileSignature) = 8);
  Move(cFileSignature, Head.Signature[0], Length(cFileSignature));
  PackLong(@Head.OldDataSize, OldFileSize);
  PackLong(@Head.NewDataSize, NewFileSize);
  WriteBin(StdOut, @Head, SizeOf(Head));
end;

{ Pack long in little-endian format to P }
{ NOTE: P must point to a block of at least 4 bytes }
procedure TBinaryPatchWriter.PackLong(P: PSignedAnsiChar; L: Integer);
begin
  P^ := L and $FF;
  Inc(P);
  P^ := (L shr 8) and $FF;
  Inc(P);
  P^ := (L shr 16) and $FF;
  Inc(P);
  P^ := (L shr 24) and $FF;
end;

{ TTextPatchWriter }

procedure TTextPatchWriter.CopyHeader(NewPos, OldPos, Length: size_t);
begin
  WriteStrFmt(
    StdOut,
    '@ -[%d] => +[%d] %d bytes'#13#10' ',
    [OldPos, NewPos, Length]
  );
end;

procedure TTextPatchWriter.Header(const OldFileName, NewFileName: string;
  const OldFileSize, NewFileSize: size_t);
begin
  WriteStrFmt(
    StdOut,
    '%% --- %s (%d bytes)'#13#10'%% +++ %s (%d bytes)'#13#10,
    [OldFileName, OldFileSize, NewFileName, NewFileSize]
  );
end;

{ TQuotedPatchWriter }

procedure TQuotedPatchWriter.Add(Data: PSignedAnsiChar; Length: size_t);
begin
  WriteStr(StdOut, '+');
  QuotedData(Data, Length);
  WriteStr(StdOut, #13#10);
end;

procedure TQuotedPatchWriter.Copy(NewBuf: PSignedAnsiCharArray; NewPos, OldPos,
  Length: size_t);
begin
  CopyHeader(NewPos, OldPos, Length);
  QuotedData(@NewBuf[NewPos], Length);
  WriteStr(StdOut, #13#10);
end;

procedure TQuotedPatchWriter.QuotedData(Data: PSignedAnsiChar; Length: size_t);
begin
  while (Length <> 0) do
  begin
    if IsPrint(Char(Data^)) and (Char(Data^) <> '\') then
      WriteStr(StdOut, Char(Data^))
    else
      WriteStr(StdOut, '\' + ByteToOct(Data^ and $FF));
    Inc(Data);
    Dec(Length);
  end;
end;

{ TFilteredPatchWriter }

procedure TFilteredPatchWriter.Add(Data: PSignedAnsiChar; Length: size_t);
begin
  WriteStr(StdOut, '+');
  FilteredData(Data, Length);
  WriteStr(StdOut, #13#10);
end;

procedure TFilteredPatchWriter.Copy(NewBuf: PSignedAnsiCharArray; NewPos,
  OldPos, Length: size_t);
begin
  CopyHeader(NewPos, OldPos, Length);
  FilteredData(@NewBuf[NewPos], Length);
  WriteStr(StdOut, #13#10);
end;

procedure TFilteredPatchWriter.FilteredData(Data: PSignedAnsiChar;
  Length: size_t);
begin
  while Length <> 0  do
  begin
    if IsPrint(Char(Data^)) then
      WriteStr(StdOut, Char(Data^))
    else
      WriteStr(StdOut, '.');
    Inc(Data);
    Dec(Length);
  end;
end;

end.
