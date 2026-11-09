#if !defined(_NET_FOSSIL_SCM_FSL_AMALGAMATION_CONFIG_H_INCLUDED_)
#define _NET_FOSSIL_SCM_FSL_AMALGAMATION_CONFIG_H_INCLUDED_ 1
/* Tweak the following for your system... */
#if !defined(HAVE_COMPRESS)
#  define HAVE_COMPRESS 1
#endif
#if !defined(HAVE_STDINT_H)
#  define HAVE_STDINT_H 1
#endif
#if defined(_WIN32)
#  if !defined(HAVE_LSTAT)
#    define HAVE_LSTAT 0
#  endif
#else
#  if !defined(HAVE_LSTAT)
#    define HAVE_LSTAT 1
#  endif
#endif
#if !defined(HAVE_OPENDIR)
#  define HAVE_OPENDIR 1
#endif
#if defined(_WIN32)
#  if !defined(HAVE_PIPE)
#    define HAVE_PIPE 0
#  endif
#else
#  if !defined(HAVE_PIPE)
#    define HAVE_PIPE 1
#  endif
#endif
#if defined(_WIN32)
#  if !defined(HAVE_STAT)
#    define HAVE_STAT 0
#  endif
#else
#  if !defined(HAVE_STAT)
#    define HAVE_STAT 1
#  endif
#endif
#if !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif
#if !defined(_XOPEN_SOURCE)
#  define _XOPEN_SOURCE 700
#endif
#if defined(_WIN32)
#  if !defined(HAVE_CLOCK_GETTIME)
#    define HAVE_CLOCK_GETTIME 0
#  endif
#else
#  if !defined(HAVE_CLOCK_GETTIME)
#    define HAVE_CLOCK_GETTIME 1
#  endif
#endif
#endif /* _NET_FOSSIL_SCM_FSL_AMALGAMATION_CONFIG_H_INCLUDED_ */
