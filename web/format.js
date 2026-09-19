// Teks berpotensi formula dijadikan teks; nilai numerik asli tetap dapat dijumlahkan.
export function csvCell(value) {
  let s=String(value??'');
  if (typeof value!=='number' && (/^[\s]*[=+\-@]/.test(s)||/^[\t\r\n]/.test(s))) s="'"+s;
  return '"'+s.replace(/"/g,'""')+'"';
}
