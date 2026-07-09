/* Memory node (genie): register one large RDMA region (the item store) and be a
 * passive one-sided target. No data-path CPU logic — the compute node drives all
 * reads/writes. usage: memnode -d <ibdev> -p <tcp_port> -n <nslots> [-P <ib_port>] [-V value_size] */
#include "rdma_kv.h"
#include "kv_layout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv){
	const char *dev = NULL; int tcp_port = 18600, ib_port = 1;
	unsigned long nslots = 1UL << 20;   /* 1M slots * 1KiB = 1 GiB default */
	unsigned vsize = 0;
	int o;
	while ((o = getopt(argc, argv, "d:p:n:P:V:h")) != -1){
		switch (o){
		case 'd': dev = optarg; break;
		case 'p': tcp_port = atoi(optarg); break;
		case 'n': nslots = strtoul(optarg, NULL, 0); break;
		case 'P': ib_port = atoi(optarg); break;
		case 'V': vsize = strtoul(optarg, NULL, 0); break;
		default: fprintf(stderr, "usage: %s -d <ibdev> -p <tcp_port> -n <nslots> [-P ib_port] [-V value_size]\n", argv[0]); return 1;
		}
	}
	if (vsize){ KV_SLOT = (vsize + KV_HDR + 7) & ~7u; }
	size_t region = (size_t)nslots * KV_SLOT;
	void *buf = aligned_alloc(4096, region);
	if (!buf){ fprintf(stderr, "alloc %zu failed\n", region); return 1; }
	memset(buf, 0, region);   /* all slots empty */
	struct rdma_conn c;
	if (rdma_kv_open(&c, dev, ib_port, buf, region)) return 1;
	fprintf(stderr, "[memnode] region %zu bytes (%lu slots x %d), waiting on tcp:%d dev:%s\n",
		region, nslots, KV_SLOT, tcp_port, dev ? dev : "(any)");
	if (rdma_kv_serve(&c, ib_port, tcp_port)) return 1;
	fprintf(stderr, "[memnode] compute node attached — serving one-sided RDMA.\n");
	/* Serve until the compute node's TCP liveness channel closes (it exited), then EXIT so a
	 * respawn wrapper re-runs us with a fresh QP for the next compute (no manual restart). */
	char b;
	while (read(c.peer_fd, &b, 1) > 0) { /* compute never writes; blocks until EOF */ }
	fprintf(stderr, "[memnode] compute detached (TCP EOF) — exiting for respawn.\n");
	return 0;
}
