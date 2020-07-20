---
layout: post
title: apache httpd and selinux
date: 2014-12-11 14:00
author: Peter.Y
category: linux
---

* content
{:toc}

Before today, I thought security on linux is just the 12 bits in one file's attributes. So i got a lesson.

I have developed a small web service using webpy on CentOS 6. It works perfectly.
But today I wanna add a function that will call another web API to get result.
The code is really simple but i just got an error:
>URL Error [Errno 13] Permission denied

Firstly I guess there must be some issues on the file previledges, so i found all the related source files and chmod them to add 'x' previledge. But the error still existed.

It confused me for about 1 hours (The good thing is I have to get deep into the code of the library, knowing details of how python implements network acess, ^_^).

Finally, I found it's selinux.

Our developing machine is enabled selinux by default. So I spent some time to 'man' it, and got basic knowledge about it.

SELinux stands for Security enhancement for Linux. The traditional method for file access previledge is quite simple. It cannot go well in some complex situations, and might involve security risk. 

SELinux defines a series of rules to refine file access previleges. Normally it has 3 mode, enforcing, permissive, and disable. When it is in enforcing mode, it will deny any invalid operations; when in permissive mode, it will never deny any invalid operations, but it will audit it; while in disable mode, it is just disabled. 

I will write another article to research and describe SELinux.

For my original problem, I'm so lucky that SELinux defines some templates for usually used softwares, apache webserver is included!
So i just run the following command
     sesetbool -P httpd_can_network 1
It is really time-consuming... about 10 seconds to take effective.

After that, the error has gone.

