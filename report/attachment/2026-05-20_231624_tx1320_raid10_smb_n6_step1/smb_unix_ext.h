/*
 * libcli/smb/smb_unix_ext.h 全文 (Samba 4.19.5 該当ヘッダ)
 * 参考: 0x200-0x2FF が UNIX CIFS Extensions 予約範囲
 */

#define MIN_UNIX_INFO_LEVEL 0x200
#define MAX_UNIX_INFO_LEVEL 0x2FF

/* qpathinfo / setpathinfo / qfileinfo / setfileinfo の info_level */
#define SMB_QUERY_FILE_UNIX_BASIC      0x200   /* UNIX File Info*/
#define SMB_SET_FILE_UNIX_BASIC        0x200
#define SMB_QUERY_FILE_UNIX_LINK       0x201
#define SMB_SET_FILE_UNIX_LINK         0x201
#define SMB_SET_FILE_UNIX_HLINK        0x203
#define SMB_QUERY_XATTR                0x205
#define SMB_QUERY_ATTR_FLAGS           0x206
#define SMB_SET_ATTR_FLAGS             0x206
#define SMB_QUERY_POSIX_PERMISSION     0x207
#define SMB_QUERY_POSIX_LOCK	       0x208
#define SMB_SET_POSIX_LOCK	       0x208
#define SMB_POSIX_PATH_OPEN	       0x209
#define SMB_POSIX_PATH_UNLINK	       0x20A
#define SMB_QUERY_FILE_UNIX_INFO2      0x20B   /* UNIX File Info2 */
#define SMB_SET_FILE_UNIX_INFO2        0x20B

/* Transact 2 Find First levels */
#define SMB_FIND_FILE_UNIX             0x202
#define SMB_FIND_FILE_UNIX_INFO2       0x20B

#define SMB_FILE_UNIX_INFO2_SIZE 116

/* TRANS2_QFSINFO / TRANS2_SETFSINFO の info_level */
#define SMB_QUERY_CIFS_UNIX_INFO      0x200    /* qfsinfo version negotiation */
#define SMB_SET_CIFS_UNIX_INFO        0x200

/* UNIX 拡張 capability bits (qfsinfo level=0x200 で client に返す) */
#define CIFS_UNIX_FCNTL_LOCKS_CAP           0x1
#define CIFS_UNIX_POSIX_ACLS_CAP            0x2
#define CIFS_UNIX_XATTTR_CAP	            0x4
#define CIFS_UNIX_EXTATTR_CAP		    0x8
#define CIFS_UNIX_POSIX_PATHNAMES_CAP	   0x10
#define CIFS_UNIX_POSIX_PATH_OPERATIONS_CAP	   0x20
#define CIFS_UNIX_LARGE_READ_CAP           0x40
#define CIFS_UNIX_LARGE_WRITE_CAP          0x80
#define CIFS_UNIX_TRANSPORT_ENCRYPTION_CAP      0x100
#define CIFS_UNIX_TRANSPORT_ENCRYPTION_MANDATORY_CAP    0x200

/* ★ TRANS2_QFSINFO の POSIX_FS_INFO (iRMC が要求する level) ★ */
#define SMB_QUERY_POSIX_FS_INFO     0x201

/* Returns FILE_SYSTEM_POSIX_INFO struct as follows (56 bytes):
      (NB   For undefined values return -1 in that field)
   le32 OptimalTransferSize;    bsize on some os, iosize on other os
   le32 BlockSize;              often 512 bytes
   le64 TotalBlocks;            redundant with other infolevels
   le64 BlocksAvail;            although redundant, easy to return
   le64 UserBlocksAvail;        bavail
   le64 TotalFileNodes;
   le64 FreeFileNodes;
   le64 FileSysIdentifier;      fsid
*/

#define SMB_QUERY_POSIX_WHO_AM_I  0x202 /* QFS Info */
#define SMB_QUERY_POSIX_WHOAMI    0x202
#define SMB_REQUEST_TRANSPORT_ENCRYPTION     0x203 /* QFSINFO */
#define SMB_ENCRYPTION_GSSAPI                0x8000

#define SMB_QUERY_POSIX_ACL  0x204
#define SMB_SET_POSIX_ACL    0x204

/* ----------------------------------------------------
 * Samba 4.19.5 で実装済み (typo bug がなければ動作する):
 * - qfsinfo level=0x200 (CIFS_UNIX_INFO)     ✓ 機能 (WITH_SMB1SERVER で正しく gate)
 * - qfsinfo level=0x201 (POSIX_FS_INFO)      ✗ ★ typo (SMB1SERVER) で永久弾き ★
 * - qfsinfo level=0x202 (WHOAMI)             ✓ 機能
 * - qpathinfo level=0x200 (FILE_UNIX_BASIC)  ✓ 機能
 * - setpathinfo level=0x209 (POSIX_PATH_OPEN)✓ 機能
 * ---------------------------------------------------- */
