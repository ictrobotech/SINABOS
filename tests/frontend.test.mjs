import {test} from 'node:test';
import assert from 'node:assert/strict';
import {csvCell} from '../web/format.js';
test('CSV melindungi teks formula dan meng-escape quote/linebreak',()=>{
 for(const value of ['=1+1','+SUM(A1:A2)','-Buku','@SUM(A1:A2)','  =HYPERLINK("url")','\tcommand','\rcommand'])assert.ok(csvCell(value).startsWith('"\''));
 assert.equal(csvCell('Buku "A";Baris\nberikut'),'"Buku ""A"";Baris\nberikut"');
});
test('CSV angka negatif tetap angka untuk rekap spreadsheet',()=>{
 assert.equal(csvCell(-30),'"-30"');assert.equal(csvCell(50),'"50"');assert.equal(csvCell(null),'""');assert.equal(csvCell('-30'),'"\'-30"');
});
