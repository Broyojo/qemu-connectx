/*
 * hwts - exercise NIC hardware timestamping end to end.
 *
 * Sets HWTSTAMP_FILTER_ALL / HWTSTAMP_TX_ON on an interface, then sends ARP
 * requests through a packet socket and checks that both the transmitted
 * request and the received reply carry a raw hardware timestamp that agrees
 * with the interface's PTP hardware clock.
 *
 * usage: hwts <iface> [target-ip] [source-ip] [count]
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/ethtool.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/net_tstamp.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define FD_TO_CLOCKID(fd) ((clockid_t)((((unsigned int)~(fd)) << 3) | 3))
#define NSEC 1000000000LL

struct arp_frame {
    struct ethhdr eth;
    struct arphdr arp;
    uint8_t sha[6];
    uint8_t spa[4];
    uint8_t tha[6];
    uint8_t tpa[4];
} __attribute__((packed));

static const char *filter_name(int f)
{
    switch (f) {
    case HWTSTAMP_FILTER_NONE: return "HWTSTAMP_FILTER_NONE";
    case HWTSTAMP_FILTER_ALL: return "HWTSTAMP_FILTER_ALL";
    default: return "other";
    }
}

static int64_t ts_ns(const struct timespec *ts)
{
    return (int64_t)ts->tv_sec * NSEC + ts->tv_nsec;
}

/* Pull the raw hardware timestamp (index 2) out of a message's cmsgs. */
static int hw_tstamp(struct msghdr *msg, struct timespec *out)
{
    struct cmsghdr *cm;

    for (cm = CMSG_FIRSTHDR(msg); cm; cm = CMSG_NXTHDR(msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET &&
            cm->cmsg_type == SO_TIMESTAMPING) {
            struct timespec *ts = (struct timespec *)CMSG_DATA(cm);

            *out = ts[2];
            return ts[2].tv_sec || ts[2].tv_nsec;
        }
    }
    return 0;
}

static int recv_ts(int fd, int flags, void *buf, size_t len,
                   struct timespec *ts, int timeout_ms)
{
    char ctrl[512];
    struct iovec iov = { buf, len };
    struct msghdr msg = {
        .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = ctrl, .msg_controllen = sizeof(ctrl),
    };
    struct pollfd pfd = { fd, (flags & MSG_ERRQUEUE) ? POLLERR : POLLIN, 0 };
    int n;

    if (poll(&pfd, 1, timeout_ms) <= 0) {
        return -1;
    }
    n = recvmsg(fd, &msg, flags);
    if (n < 0) {
        return -1;
    }
    return hw_tstamp(&msg, ts) ? n : -2;
}

int main(int argc, char **argv)
{
    const char *ifname = argc > 1 ? argv[1] : "eth0";
    const char *target = argc > 2 ? argv[2] : "10.0.2.2";
    const char *source = argc > 3 ? argv[3] : "10.0.2.15";
    int count = argc > 4 ? atoi(argv[4]) : 5;
    struct hwtstamp_config cfg = {
        .tx_type = HWTSTAMP_TX_ON,
        .rx_filter = HWTSTAMP_FILTER_ALL,
    };
    struct ethtool_ts_info info = { .cmd = ETHTOOL_GET_TS_INFO };
    struct sockaddr_ll ll = { .sll_family = AF_PACKET };
    struct arp_frame req;
    struct ifreq ifr;
    char path[64];
    int fd, phc, i, fails = 0;
    int flags = SOF_TIMESTAMPING_TX_HARDWARE | SOF_TIMESTAMPING_RX_HARDWARE |
                SOF_TIMESTAMPING_RAW_HARDWARE;
    int64_t last_rx = 0;

    fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ARP));
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    ifr.ifr_data = (void *)&cfg;
    if (ioctl(fd, SIOCSHWTSTAMP, &ifr) < 0) {
        printf("SIOCSHWTSTAMP(HWTSTAMP_FILTER_ALL) failed: %s\n",
               strerror(errno));
        return 1;
    }
    printf("SIOCSHWTSTAMP ok: tx_type=%d rx_filter=%d (%s)\n",
           cfg.tx_type, cfg.rx_filter, filter_name(cfg.rx_filter));
    if (cfg.rx_filter != HWTSTAMP_FILTER_ALL || cfg.tx_type != HWTSTAMP_TX_ON) {
        printf("driver did not grant HWTSTAMP_FILTER_ALL\n");
        return 1;
    }

    ifr.ifr_data = (void *)&info;
    if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
        perror("ETHTOOL_GET_TS_INFO");
        return 1;
    }
    printf("ts_info: phc_index=%d so_timestamping=0x%x tx_types=0x%x "
           "rx_filters=0x%x\n", info.phc_index, info.so_timestamping,
           info.tx_types, info.rx_filters);
    if (info.phc_index < 0) {
        printf("no PTP hardware clock\n");
        return 1;
    }
    snprintf(path, sizeof(path), "/dev/ptp%d", info.phc_index);
    phc = open(path, O_RDONLY);
    if (phc < 0) {
        perror(path);
        return 1;
    }

    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        perror("SIOCGIFINDEX");
        return 1;
    }
    ll.sll_ifindex = ifr.ifr_ifindex;
    ll.sll_protocol = htons(ETH_P_ARP);
    if (bind(fd, (struct sockaddr *)&ll, sizeof(ll)) < 0) {
        perror("bind");
        return 1;
    }
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) {
        perror("SIOCGIFHWADDR");
        return 1;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING, &flags, sizeof(flags))) {
        perror("SO_TIMESTAMPING");
        return 1;
    }

    memset(&req, 0, sizeof(req));
    memset(req.eth.h_dest, 0xff, 6);
    memcpy(req.eth.h_source, ifr.ifr_hwaddr.sa_data, 6);
    req.eth.h_proto = htons(ETH_P_ARP);
    req.arp.ar_hrd = htons(ARPHRD_ETHER);
    req.arp.ar_pro = htons(ETH_P_IP);
    req.arp.ar_hln = 6;
    req.arp.ar_pln = 4;
    req.arp.ar_op = htons(ARPOP_REQUEST);
    memcpy(req.sha, ifr.ifr_hwaddr.sa_data, 6);
    inet_pton(AF_INET, source, req.spa);
    inet_pton(AF_INET, target, req.tpa);

    for (i = 0; i < count; i++) {
        struct timespec tx, rx, now;
        struct arp_frame rep;
        uint8_t junk[2048];
        int64_t t_tx, t_rx, t_now;
        int n, tries;

        if (send(fd, &req, sizeof(req), 0) != sizeof(req)) {
            perror("send");
            return 1;
        }
        n = recv_ts(fd, MSG_ERRQUEUE, junk, sizeof(junk), &tx, 2000);
        if (n < 0) {
            printf("[%d] no TX hardware timestamp (%d)\n", i, n);
            fails++;
            continue;
        }

        /* Skip unrelated ARP traffic until our reply shows up. */
        for (tries = 0, n = -1; tries < 20; tries++) {
            n = recv_ts(fd, 0, &rep, sizeof(rep), &rx, 2000);
            if (n == -1) {
                break;
            }
            if (rep.arp.ar_op == htons(ARPOP_REPLY) &&
                !memcmp(rep.spa, req.tpa, 4)) {
                break;
            }
            n = -1;
        }
        if (n < 0) {
            printf("[%d] no RX hardware timestamp (%d)\n", i, n);
            fails++;
            continue;
        }
        clock_gettime(FD_TO_CLOCKID(phc), &now);
        t_tx = ts_ns(&tx);
        t_rx = ts_ns(&rx);
        t_now = ts_ns(&now);
        printf("[%d] tx=%lld.%09lld rx=%lld.%09lld rx-tx=%lldns "
               "phc-rx=%lldns\n", i,
               (long long)(t_tx / NSEC), (long long)(t_tx % NSEC),
               (long long)(t_rx / NSEC), (long long)(t_rx % NSEC),
               (long long)(t_rx - t_tx), (long long)(t_now - t_rx));
        /* Timestamps must be ordered and close to the PHC's idea of now. */
        if (t_rx < t_tx || t_now < t_rx || t_now - t_tx > NSEC ||
            t_tx <= last_rx) {
            printf("[%d] timestamps out of order or far from PHC\n", i);
            fails++;
        }
        last_rx = t_rx;
        usleep(100000);
    }

    printf(fails ? "HWTS FAIL (%d/%d)\n" : "HWTS PASS\n", fails, count);
    return fails != 0;
}
