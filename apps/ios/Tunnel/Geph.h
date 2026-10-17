// The C interface of geph5-client (binaries/geph5-client/src/lib.rs).
#include <stdint.h>

int start_client(const char *cfg, int vpn_fd);
int send_pkt(const char *pkt, int pkt_len);
int recv_pkt(char *out_buf, int out_buflen);
int daemon_rpc(const char *jrpc_req, char *out_buf, int out_buflen);
