import {Marked} from 'marked';
import hljs from 'highlight.js/lib/core';
import {parser} from '@lezer/python';
import python from 'highlight.js/lib/languages/python';
import javascript from 'highlight.js/lib/languages/javascript';
import typescript from 'highlight.js/lib/languages/typescript';
import json from 'highlight.js/lib/languages/json';
import bash from 'highlight.js/lib/languages/bash';
import sql from 'highlight.js/lib/languages/sql';
import rust from 'highlight.js/lib/languages/rust';
for (const [name, grammar] of Object.entries({python,javascript,typescript,json,bash,sql,rust})) hljs.registerLanguage(name,grammar);
function bounded(source) { if (typeof source !== 'string' || source.length > 100000) throw Error('Text exceeds 100,000 UTF-16 units'); }
const markdown = new Marked({gfm:true, extensions:[
 {name:'math',level:'block',start:s=>s.search(/^ {0,3}\$\$[ \t]*\r?$/m),tokenizer(s){const m=/^ {0,3}\$\$[ \t]*\r?\n([\s\S]*?)\r?\n {0,3}\$\$[ \t]*(?:\r?\n|$)/.exec(s);if(m)return {type:'math',raw:m[0],text:m[1],display:true};}},
 {name:'math',level:'inline',start:s=>s.indexOf('$'),tokenizer(s){if(s[0]!=='$'||s[1]==='$'||!s[1]||/\s/.test(s[1]))return;for(let i=1;i<s.length&&s[i]!=='\n';i++){if(s[i]==='\\'){i++;continue;}if(s[i]==='$'){if(s[i+1]==='$'||/\s/.test(s[i-1]))return;return {type:'math',raw:s.slice(0,i+1),text:s.slice(1,i),display:false};}}}}
]});
export function parseMarkdown(source){bounded(source);return JSON.stringify({source,tokens:markdown.lexer(source)});}
const aliases={py:'python',js:'javascript',ts:'typescript',sh:'bash',shell:'bash',rs:'rust'};
const colors={keyword:'#6f42c1',literal:'#6f42c1',built_in:'#005cc5',type:'#005cc5',string:'#075b35',regexp:'#075b35',comment:'#59636e',quote:'#59636e',number:'#005cc5',title:'#825000',attr:'#825000',attribute:'#825000',meta:'#6f42c1',variable:'#b03030',symbol:'#b03030',substitution:'#b03030'};
export function analyzeCode(source,info=''){
 bounded(source);let language=info.trim().split(/\s+/)[0].toLowerCase();language=aliases[language]||language;
 let spans=[{text:source}];const diagnostics=[];
 if(!hljs.getLanguage(language))return JSON.stringify({spans,diagnostics});
 try{const root=hljs.highlight(source,{language,ignoreIllegals:true})._emitter.rootNode;const result=[];const stack=[[root,undefined]];while(stack.length){const [node,color]=stack.pop();if(typeof node==='string'){const last=result[result.length-1];if(last&&last.color===color)last.text+=node;else result.push({text:node,color});}else{const next=colors[(node.scope||'').split('.')[0]]||color;for(let i=node.children.length-1;i>=0;i--)stack.push([node.children[i],next]);}}if(result.map(s=>s.text).join('')===source)spans=result;}catch{}
 if(language==='python'){const starts=[0];for(let i=0;i<source.length;i++)if(source[i]==='\n')starts.push(i+1);try{parser.parse(source).iterate({enter(n){if(!n.type.isError||diagnostics.length>=100)return;let low=0,high=starts.length-1;while(low<high){const m=Math.ceil((low+high)/2);if(starts[m]<=n.from)low=m;else high=m-1;}const line=low+1;if(diagnostics[diagnostics.length-1]?.line!==line)diagnostics.push({line,from:n.from,to:n.to,message:'Python syntax error'});}});}catch{diagnostics.push({line:1,from:0,to:0,message:'Python syntax analysis exceeded its limits'});}}
 return JSON.stringify({spans,diagnostics});
}

// Portable synthetic checks, excluded from the JavaScriptCore bundle by esbuild.
if (typeof process !== 'undefined' && process.argv?.includes('--test')) {
 const assert = (ok) => { if (!ok) throw Error('Parser regression'); };
 for (const source of ['', '# Header\n\n$x$ and **strong**', '$$\nx^2\n$$', '<unknown>raw</unknown>', '👩🏽‍💻\r\n日本語', '| a | b |\n|---|---|\n|1|2|']) {
  const parsed=JSON.parse(parseMarkdown(source));assert(parsed.source===source);assert(parsed.tokens.map(t=>t.raw).join('')===source.replace(/\r\n?/g,'\n'));
 }
 assert(JSON.parse(parseMarkdown('$x$')).tokens[0].tokens[0].type==='math');
 assert(JSON.parse(parseMarkdown('$ x$')).tokens[0].tokens[0].type!=='math');
 for(const language of ['python','py','js','ts','json','bash','sql','rust','unknown']){const source='def f(:\n  return "👩🏽‍💻"\n';const result=JSON.parse(analyzeCode(source,language));assert(result.spans.map(s=>s.text).join('')===source);if(language==='python'||language==='py')assert(result.diagnostics.length>0);else assert(result.diagnostics.length===0);}
 assert(JSON.parse(analyzeCode('unknown_name + 1','python')).diagnostics.length===0);
 let threw=false;try{parseMarkdown('x'.repeat(100001));}catch{threw=true;}assert(threw);
 console.log('Text parser synthetic checks passed');
}
