/*
 * Samba 4.19.5 ソース該当箇所 抜粋 (s-quizzical-wozniak, 2026-05-20)
 * 取得元: https://download.samba.org/pub/samba/stable/samba-4.19.5.tar.gz
 *         sha256: 0e2405b4cec29d0459621f4340a1a74af771ec7cffedff43250cad7f1f87605e
 */

/* =============================================================
 * 1. libcli/smb/smb_unix_ext.h:218 — 0x201 定義
 * ============================================================= */

/* Info level for TRANS2_QFSINFO - returns version of CIFS UNIX extensions, plus
   64-bits worth of capability fun :-).
   Use the same info level for TRANS2_SETFSINFO */
#define SMB_QUERY_CIFS_UNIX_INFO      0x200
#define SMB_SET_CIFS_UNIX_INFO        0x200
/* ... */
#define SMB_QUERY_POSIX_FS_INFO     0x201

/* Returns FILE_SYSTEM_POSIX_INFO struct as follows
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

/* =============================================================
 * 2. source3/include/trans2.h:415 — SMB2 level
 * ============================================================= */

#define SMB2_FS_POSIX_INFORMATION_INTERNAL              1100

/* =============================================================
 * 3. source3/smbd/smb1_trans2.c:1647-1697 — call_trans2qfsinfo
 *    (level を抽出して smbd_do_qfsinfo に渡すだけ)
 * ============================================================= */

static void call_trans2qfsinfo(connection_struct *conn,
			       struct smb_request *req,
			       char **pparams, int total_params,
			       char **ppdata, int total_data,
			       unsigned int max_data_bytes)
{
	char *params = *pparams;
	uint16_t info_level;
	int data_len = 0;
	size_t fixed_portion;
	NTSTATUS status;

	if (total_params < 2) {
		reply_nterror(req, NT_STATUS_INVALID_PARAMETER);
		return;
	}

	info_level = SVAL(params,0);

	if (ENCRYPTION_REQUIRED(conn) && !req->encrypted) {
		if (info_level != SMB_QUERY_CIFS_UNIX_INFO) {
			DEBUG(0,("call_trans2qfsinfo: encryption required "
				"and info level 0x%x sent.\n",
				(unsigned int)info_level));
			reply_nterror(req, NT_STATUS_ACCESS_DENIED);
			return;
		}
	}

	DEBUG(3,("call_trans2qfsinfo: level = %d\n", info_level));

	status = smbd_do_qfsinfo(req->xconn, conn, req,
				 info_level,
				 req->flags2,
				 max_data_bytes,
				 &fixed_portion,
				 NULL,
				 ppdata, &data_len);
	if (!NT_STATUS_IS_OK(status)) {
		reply_nterror(req, status);  /* ← line 1686 — Samba log の error 出力位置 */
		return;
	}

	send_trans2_replies(conn, req, NT_STATUS_OK, params, 0, *ppdata, data_len,
			    max_data_bytes);

	DEBUG( 4, ( "%s info_level = %d\n",
		    smb_fn_name(req->cmd), info_level) );

	return;
}

/* =============================================================
 * 4. source3/smbd/smb2_trans2.c:2018-2033 — ★ TYPO BUG ★
 *    fsinfo_unix_valid_level (SMB1 SMB_QUERY_POSIX_FS_INFO を永久に弾く)
 * ============================================================= */

static bool fsinfo_unix_valid_level(connection_struct *conn,
				    uint16_t info_level)
{
	if (conn->sconn->using_smb2 &&
			lp_smb3_unix_extensions() &&
			info_level == SMB2_FS_POSIX_INFORMATION_INTERNAL) {
		return true;
	}
#if defined(SMB1SERVER)             /* ★★★ TYPO: 正しくは WITH_SMB1SERVER ★★★ */
	if (lp_smb1_unix_extensions() &&
			info_level == SMB_QUERY_POSIX_FS_INFO) {
		return true;
	}
#endif
	return false;
}

/* =============================================================
 * 5. source3/smbd/smb2_trans2.c:2532-2564 — case SMB_QUERY_POSIX_FS_INFO
 *    (case 自体は存在するが fsinfo_unix_valid_level で弾かれて
 *     INVALID_LEVEL を返してしまう)
 * ============================================================= */

		case SMB_QUERY_POSIX_FS_INFO:
		case SMB2_FS_POSIX_INFORMATION_INTERNAL:
		{
			int rc;
			struct vfs_statvfs_struct svfs;

			if (!fsinfo_unix_valid_level(conn, info_level)) {
				return NT_STATUS_INVALID_LEVEL;  /* ← ★ 全 cycle で iRMC へ返るエラー ★ */
			}

			rc = SMB_VFS_STATVFS(conn, &smb_fname, &svfs);

			if (!rc) {
				data_len = 56;
				SIVAL(pdata,0,svfs.OptimalTransferSize);
				SIVAL(pdata,4,svfs.BlockSize);
				SBIG_UINT(pdata,8,svfs.TotalBlocks);
				SBIG_UINT(pdata,16,svfs.BlocksAvail);
				SBIG_UINT(pdata,24,svfs.UserBlocksAvail);
				SBIG_UINT(pdata,32,svfs.TotalFileNodes);
				SBIG_UINT(pdata,40,svfs.FreeFileNodes);
				SBIG_UINT(pdata,48,svfs.FsIdentifier);
				DEBUG(5,("smbd_do_qfsinfo : SMB_QUERY_POSIX_FS_INFO succsessful\n"));
#ifdef EOPNOTSUPP
			} else if (rc == EOPNOTSUPP) {
				return NT_STATUS_INVALID_LEVEL;
#endif /* EOPNOTSUPP */
			} else {
				DEBUG(0,("vfs_statvfs() failed for service [%s]\n",lp_servicename(talloc_tos(), lp_sub, SNUM(conn))));
				return NT_STATUS_DOS(ERRSRV, ERRerror);
			}
			break;
		}

/* =============================================================
 * 6. wscript:421 — WITH_SMB1SERVER define
 * ============================================================= */

	if Options.options.with_smb1server != False:
		conf.DEFINE('WITH_SMB1SERVER', '1')

/* =============================================================
 * 7. 対比: source3/smbd/smb2_trans2.c:2477 — case SMB_QUERY_CIFS_UNIX_INFO
 *    (こちらは WITH_ 付きで正しく gate されている)
 * ============================================================= */

#if defined(WITH_SMB1SERVER)        /* ← 正しい macro */
		/*
		 * Query the version and capabilities of the CIFS UNIX extensions
		 * in use.
		 */

		case SMB_QUERY_CIFS_UNIX_INFO:
		{
			/* ... */
			break;
		}
#endif
