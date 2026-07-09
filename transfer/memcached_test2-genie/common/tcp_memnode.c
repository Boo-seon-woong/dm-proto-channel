/* TCP-backend memory node (genie): same fixed-slot item store as memnode, but served over a plain
 * TCP request/response socket instead of one-sided RDMA. Ablation partner for the RDMA memnode —
 * lets the SAME custom KVS (compute + fixed slots) be measured with TCP vs RDMA as the only change.
 * Exits when the compute detaches (TCP EOF) so a respawn wrapper restarts it. Not a peer binary —
 * runs on the memory node. usage: tcp_memnode -p <tcp_port> -n <nslots> [-V value_size] */
#include "rdma_kv.h"
#include "kv_layout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv){
	int tcp_port = 18601; unsigned long nslots = 1UL << 20; unsigned vsize = 0;
	int o;
	while ((o = getopt(argc, argv, "p:n:V:h")) != -1){
		switch (o){
		case 'p': tcp_port = atoi(optarg); break;
		case 'n': nslots = strtoul(optarg, NULL, 0); break;
		case 'V': vsize = strtoul(optarg, NULL, 0); break;
		default: fprintf(stderr, "usage: %s -p <tcp_port> -n <nslots> [-V value_size]\n", argv[0]); return 1;
		}
	}
	if (vsize){ KV_SLOT = (vsize + KV_HDR + 7) & ~7u; }
	size_t region = (size_t)nslots * KV_SLOT;
	void *store = aligned_alloc(4096, region);
	if (!store){ fprintf(stderr, "alloc %zu failed\n", region); return 1; }
	memset(store, 0, region);
	fprintf(stderr, "[tcp_memnode] region %zu bytes (%lu slots x %d), waiting on tcp:%d\n",
		region, nslots, KV_SLOT, tcp_port);
	if (rdma_kv_serve_tcp(tcp_port, store, region)) return 1;
	fprintf(stderr, "[tcp_memnode] compute detached (TCP EOF) — exiting for respawn.\n");
	return 0;
}
