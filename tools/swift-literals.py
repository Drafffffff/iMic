import re,json,pathlib

def tokens(s):
    i=0
    def string(start):
        q='"""' if s.startswith('"""',start) else '"';j=start+len(q)
        while j<len(s):
            if s.startswith(q,j):return j+len(q)
            if s.startswith('\\(',j):
                j+=2;depth=1
                while j<len(s) and depth:
                    if s[j]=='"':j=string(j);continue
                    if s[j]=='(':depth+=1
                    if s[j]==')':depth-=1
                    j+=1
            elif s[j]=='\\':j+=2
            else:j+=1
        return j
    while i<len(s):
        if s.startswith('//',i):
            j=s.find('\n',i);i=j if j>=0 else len(s)
        elif s.startswith('/*',i):
            j=s.find('*/',i+2);i=j+2 if j>=0 else len(s)
        elif s[i]=='"':
            j=string(i);yield i,j,s[i:j];i=j
        else:i+=1
