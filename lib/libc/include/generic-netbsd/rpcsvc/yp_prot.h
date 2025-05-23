/*	$NetBSD: yp_prot.h,v 1.20 2020/04/02 15:30:25 msaitoh Exp $	*/

/*
 * Copyright (c) 1992, 1993 Theo de Raadt <deraadt@fsa.ca>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#ifndef _RPCSVC_YP_PROT_H_
#define _RPCSVC_YP_PROT_H_

#include <rpc/rpc.h> /* for XDR */

/*
 * YPSERV PROTOCOL:
 * 
 * ypserv supports the following procedures:
 * 
 * YPPROC_NULL		takes (void), returns (void).
 * 			called to check if server is alive.
 * YPPROC_DOMAIN	takes (char *), returns (bool_t).
 * 			true if ypserv serves the named domain.
 * YPPROC_DOMAIN_NOACK	takes (char *), returns (bool_t).
 * 			true if ypserv serves the named domain.
 *			used for broadcasts, does not ack if ypserv
 *			doesn't handle named domain.
 * YPPROC_MATCH		takes (struct ypreq_key), returns (struct ypresp_val)
 * 			does a lookup.
 * YPPROC_FIRST		takes (struct ypreq_nokey) returns (ypresp_key_val).
 * 			gets the first key/datum from the map.
 * YPPROC_NEXT		takes (struct ypreq_key) returns (ypresp_key_val).
 * 			gets the next key/datum from the map.
 * YPPROC_XFR		takes (struct ypreq_xfr), returns (void).
 * 			tells ypserv to check if there is a new version of
 *			the map.
 * YPPROC_CLEAR		takes (void), returns (void).
 * 			tells ypserv to flush its file cache, so that
 *			newly transferred files will get read.
 * YPPROC_ALL		takes (struct ypreq_nokey), returns (bool_t and
 *			struct ypresp_key_val).
 * 			returns an array of data, with the bool_t being
 * 			false on the last datum. read the source, it's
 *			convoluted.
 * YPPROC_MASTER	takes (struct ypreq_nokey), returns (ypresp_master).
 * YPPROC_ORDER		takes (struct ypreq_nokey), returns (ypresp_order).
 * YPPROC_MAPLIST	takes (char *), returns (struct ypmaplist *).
 */

/* Program and version symbols, magic numbers */
#define YPPROG		((unsigned long)100004)
#define YPVERS		((unsigned long)2)
#define YPVERS_ORIG	((unsigned long)1)

#define YPMAXRECORD	1024
#define YPMAXDOMAIN	64
#define YPMAXMAP	64
#define YPMAXPEER	256

/*
 * I don't know if anything of sun's depends on this, or if they
 * simply defined it so that their own code wouldn't try to send
 * packets over the ethernet MTU. This YP code doesn't use it.
 */
#define YPMSGSZ		1600

#ifndef DATUM
typedef struct {
	const char	*dptr;
	int		 dsize;
} datum;
#define DATUM
#endif

struct ypmap_parms {
	const char *domain;
	const char *map;
	unsigned int ordernum;
	char *owner;
};

struct ypreq_key {
	const char *domain;
	const char *map;
	datum keydat;
};

struct ypreq_nokey {
	const char *domain;
	const char *map;
};

struct ypreq_xfr {
	struct ypmap_parms map_parms;
	unsigned int transid;
	unsigned int proto;
	unsigned int port;
};
#define ypxfr_domain	map_parms.domain
#define ypxfr_map	map_parms.map
#define ypxfr_ordernum	map_parms.ordernum
#define ypxfr_owner	map_parms.owner

struct ypresp_val {
	unsigned int status;
	datum valdat;
};

struct ypresp_key_val {
	unsigned int status;
	datum keydat;
	datum valdat;
};

struct ypresp_master {
	unsigned int status;
	char *master;
};

struct ypresp_order {
	unsigned int status;
	unsigned int ordernum;
};

struct ypmaplist {
	char ypml_name[YPMAXMAP + 1];
	struct ypmaplist *ypml_next;
};

struct ypresp_maplist {
	unsigned int status;
	struct ypmaplist *list;
};

/* ypserv procedure numbers */
#define YPPROC_NULL		((unsigned long)0)
#define YPPROC_DOMAIN		((unsigned long)1)
#define YPPROC_DOMAIN_NONACK	((unsigned long)2)
#define YPPROC_MATCH		((unsigned long)3)
#define YPPROC_FIRST		((unsigned long)4)
#define YPPROC_NEXT		((unsigned long)5)
#define YPPROC_XFR		((unsigned long)6)
#define YPPROC_CLEAR		((unsigned long)7)
#define YPPROC_ALL		((unsigned long)8)
#define YPPROC_MASTER		((unsigned long)9)
#define YPPROC_ORDER		((unsigned long)10)
#define YPPROC_MAPLIST		((unsigned long)11)

/* ypserv procedure return status values */
#define YP_TRUE	 	((unsigned int)1)	/* general purpose success code */
#define YP_NOMORE 	((unsigned int)2)	/* no more entries in map */
#define YP_FALSE 	((unsigned int)0)	/* general purpose failure code */
#define YP_NOMAP 	((unsigned int)-1)	/* no such map in domain */
#define YP_NODOM 	((unsigned int)-2)	/* domain not supported */
#define YP_NOKEY 	((unsigned int)-3)	/* no such key in map */
#define YP_BADOP 	((unsigned int)-4)	/* invalid operation */
#define YP_BADDB 	((unsigned int)-5)	/* server data base is bad */
#define YP_YPERR 	((unsigned int)-6)	/* YP server error */
#define YP_BADARGS 	((unsigned int)-7)	/* request arguments bad */
#define YP_VERS		((unsigned int)-8)	/* YP server version mismatch */

/*
 * Sun's header file says:
 * "Domain binding data structure, used by ypclnt package and ypserv modules.
 * Users of the ypclnt package (or of this protocol) don't HAVE to know about
 * it, but it must be available to users because _yp_dobind is a public
 * interface."
 * 
 * This is totally bogus! Nowhere else does Sun state that _yp_dobind() is
 * a public interface, and I don't know any reason anyone would want to call
 * it. But, just in case anyone does actually expect it to be available..
 * we provide this.. exactly as Sun wants it.
 */
struct dom_binding {
	struct dom_binding *dom_pnext;
	char dom_domain[YPMAXDOMAIN + 1];
	struct sockaddr_in dom_server_addr;
	u_short dom_server_port;
	int dom_socket;
	CLIENT *dom_client;
	u_short dom_local_port;
	long dom_vers;
};

/*
 * YPBIND PROTOCOL:
 * 
 * ypbind supports the following procedures:
 *
 * YPBINDPROC_NULL	takes (void), returns (void).
 *			to check if ypbind is running.
 * YPBINDPROC_DOMAIN	takes (char *), returns (struct ypbind_resp).
 *			requests that ypbind start to serve the
 *			named domain (if it doesn't already)
 * YPBINDPROC_SETDOM	takes (struct ypbind_setdom), returns (void).
 *			used by ypset.
 */
 
#define YPBINDPROG		((unsigned long)100007)
#define YPBINDVERS		((unsigned long)2)
#define YPBINDVERS_ORIG		((unsigned long)1)

/* ypbind procedure numbers */
#define YPBINDPROC_NULL		((unsigned long)0)
#define YPBINDPROC_DOMAIN	((unsigned long)1)
#define YPBINDPROC_SETDOM	((unsigned long)2)

/* error code in ypbind_resp.ypbind_status */
enum ypbind_resptype {
	YPBIND_SUCC_VAL = 1,
	YPBIND_FAIL_VAL = 2
};

/* network order, of course */
struct ypbind_binding {
	struct in_addr	ypbind_binding_addr;
	uint16_t	ypbind_binding_port;
};

struct ypbind_resp {
	enum ypbind_resptype	ypbind_status;
	union {
		unsigned int		ypbind_error;
		struct ypbind_binding	ypbind_bindinfo;
	} ypbind_respbody;
};

/* error code in ypbind_resp.ypbind_respbody.ypbind_error */
#define YPBIND_ERR_ERR		1	/* internal error */
#define YPBIND_ERR_NOSERV	2	/* no bound server for passed domain */
#define YPBIND_ERR_RESC		3	/* system resource allocation failure */

/*
 * Request data structure for ypbind "Set domain" procedure.
 */
struct ypbind_setdom {
	char ypsetdom_domain[YPMAXDOMAIN + 1];
	struct ypbind_binding ypsetdom_binding;
	unsigned int ypsetdom_vers;
};
#define ypsetdom_addr ypsetdom_binding.ypbind_binding_addr
#define ypsetdom_port ypsetdom_binding.ypbind_binding_port

/*
 * YPPUSH PROTOCOL:
 * 
 * Sun says:
 * "Protocol between clients (ypxfr, only) and yppush
 *  yppush speaks a protocol in the transient range, which
 *  is supplied to ypxfr as a command-line parameter when it
 *  is activated by ypserv."
 * 
 * This protocol is not implemented, naturally, because this YP
 * implementation only does the client side.
 */
#define YPPUSHVERS		((unsigned long)1)
#define YPPUSHVERS_ORIG		((unsigned long)1)

/* yppush procedure numbers */
#define YPPUSHPROC_NULL		((unsigned long)0)
#define YPPUSHPROC_XFRRESP	((unsigned long)1)

struct yppushresp_xfr {
	unsigned int	transid;
	unsigned int	status;
};

/* yppush status value in yppushresp_xfr.status */
#define YPPUSH_SUCC	((unsigned int)1)	/* Success */
#define YPPUSH_AGE	((unsigned int)2)	/* Master's version not newer */
#define YPPUSH_NOMAP 	((unsigned int)-1)	/* Can't find server for map */
#define YPPUSH_NODOM 	((unsigned int)-2)	/* Domain not supported */
#define YPPUSH_RSRC 	((unsigned int)-3)	/* Local resource alloc failure */
#define YPPUSH_RPC 	((unsigned int)-4)	/* RPC failure talking to server */
#define YPPUSH_MADDR	((unsigned int)-5)	/* Can't get master address */
#define YPPUSH_YPERR 	((unsigned int)-6)	/* YP server/map db error */
#define YPPUSH_BADARGS 	((unsigned int)-7)	/* Request arguments bad */
#define YPPUSH_DBM	((unsigned int)-8)	/* Local dbm operation failed */
#define YPPUSH_FILE	((unsigned int)-9)	/* Local file I/O operation failed */
#define YPPUSH_SKEW	((unsigned int)-10)	/* Map version skew during transfer */
#define YPPUSH_CLEAR	((unsigned int)-11)	/* Can't send "Clear" req to local ypserv */
#define YPPUSH_FORCE	((unsigned int)-12)	/* No local order number in map - use -f */
#define YPPUSH_XFRERR	((unsigned int)-13)	/* ypxfr error */
#define YPPUSH_REFUSED	((unsigned int)-14)	/* Transfer request refused by ypserv */

struct ypall_callback;

__BEGIN_DECLS
bool_t xdr_domainname(XDR *, char *);	/* obsolete */
bool_t xdr_peername(XDR *, char *);	/* obsolete */
bool_t xdr_mapname(XDR *, char *);	/* obsolete */
bool_t xdr_datum(XDR *, datum *);
bool_t xdr_ypdomain_wrap_string(XDR *, char **);
bool_t xdr_ypmap_wrap_string(XDR *, char **);
bool_t xdr_ypreq_key(XDR *, struct ypreq_key *);
bool_t xdr_ypreq_nokey(XDR *, struct ypreq_nokey *);
bool_t xdr_ypreq_xfr(XDR *, struct ypreq_xfr *);
bool_t xdr_ypresp_val(XDR *, struct ypresp_val *);
bool_t xdr_ypresp_key_val(XDR *, struct ypresp_key_val *);
bool_t xdr_ypmap_parms(XDR *, struct ypmap_parms *);
bool_t xdr_ypowner_wrap_string(XDR *, char **);
bool_t xdr_yppushresp_xfr(XDR *, struct yppushresp_xfr *);
bool_t xdr_ypresp_order(XDR *, struct ypresp_order *);
bool_t xdr_ypresp_master(XDR *, struct ypresp_master *);
bool_t xdr_ypall(XDR *, struct ypall_callback *);
bool_t xdr_ypresp_maplist(XDR *, struct ypresp_maplist *);
bool_t xdr_ypbind_resp(XDR *, struct ypbind_resp *);
bool_t xdr_ypbind_setdom(XDR *, struct ypbind_setdom *);
bool_t xdr_ypmaplist(XDR *, struct ypmaplist *);
bool_t xdr_yp_inaddr(XDR *, struct in_addr *);
__END_DECLS

#endif /* _RPCSVC_YP_PROT_H_ */