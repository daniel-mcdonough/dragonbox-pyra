/*
 * inotify-delete-race: does a file still exist when its IN_DELETE arrives?
 *
 * This is what `udevadm settle` does with /run/udev/queue: wait on inotify
 * IN_DELETE through epoll, then access() the name. One process (the deleter)
 * creates and unlinks a file in a tmpfs directory N times. The other (the
 * waiter) counts how often access() on the deleted name still succeeds.
 *
 *   gcc -O2 -o inotify-delete-race inotify-delete-race.c
 *   ./inotify-delete-race DIR N WAITER_CPU DELETER_CPU
 *
 * DIR must be on tmpfs (for example a fresh directory under /run). The CPU
 * arguments pin each process; -1 leaves it unpinned. On a kernel that sends
 * IN_DELETE before d_delete() (v5.3 to v5.16 without upstream a37d9a17f099)
 * the same-CPU case reports stale hits.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/wait.h>
#include <unistd.h>

static void pin(int cpu)
{
	cpu_set_t set;

	if (cpu < 0)
		return;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set) < 0) {
		perror("sched_setaffinity");
		exit(1);
	}
}

int main(int argc, char **argv)
{
	char path[PATH_MAX], buf[4096];
	int n, wcpu, dcpu, in, ep, fd, seen = 0, stale = 0;
	struct epoll_event ev = { .events = EPOLLIN };
	pid_t pid;

	if (argc != 5) {
		fprintf(stderr, "usage: %s DIR N WAITER_CPU DELETER_CPU\n", argv[0]);
		return 2;
	}
	n = atoi(argv[2]);
	wcpu = atoi(argv[3]);
	dcpu = atoi(argv[4]);
	snprintf(path, sizeof(path), "%s/queue", argv[1]);

	in = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
	ep = epoll_create1(EPOLL_CLOEXEC);
	if (in < 0 || ep < 0 || inotify_add_watch(in, argv[1], IN_DELETE) < 0 ||
	    epoll_ctl(ep, EPOLL_CTL_ADD, in, &ev) < 0) {
		perror("setup");
		return 1;
	}

	pid = fork();
	if (pid == 0) {
		pin(dcpu);
		for (int i = 0; i < n; i++) {
			fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
			if (fd >= 0)
				close(fd);
			usleep(2000);	/* let the waiter go back to sleep */
			unlink(path);
			usleep(2000);
		}
		_exit(0);
	}

	pin(wcpu);
	while (seen < n) {
		struct epoll_event out;
		ssize_t len;

		if (epoll_wait(ep, &out, 1, 5000) <= 0)
			break;	/* deleter finished or stalled */
		len = read(in, buf, sizeof(buf));
		for (char *p = buf; len > 0 && p < buf + len;) {
			struct inotify_event *e = (struct inotify_event *)p;

			if ((e->mask & IN_DELETE) && e->len && !strcmp(e->name, "queue")) {
				seen++;
				if (access(path, F_OK) == 0)
					stale++;
			}
			p += sizeof(*e) + e->len;
		}
	}
	waitpid(pid, NULL, 0);
	unlink(path);
	printf("waiter cpu %d, deleter cpu %d: %d IN_DELETE seen, %d with the file still there\n",
	       wcpu, dcpu, seen, stale);
	return 0;
}
