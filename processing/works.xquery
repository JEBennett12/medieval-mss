import module namespace bod = "http://www.bodleian.ox.ac.uk/bdlss" at "lib/msdesc2solr.xquery";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare option saxon:output "indent=yes";

(: Read authority file :)
declare variable $authorityentries := doc("../works.xml")/tei:TEI/tei:text/tei:body/tei:listBibl/tei:bibl[@xml:id];

(: Find instances in manuscript description files, building in-memory data structure, to avoid having to search across all files for each authority file entry :)
declare variable $allinstances :=
    for $instance in collection('../collections?select=*.xml;recurse=yes')//tei:title
        let $roottei := $instance/ancestor::tei:TEI
        let $shelfmark := ($roottei/tei:teiHeader/tei:fileDesc/tei:sourceDesc/tei:msDesc/tei:msIdentifier/tei:idno[@type = "shelfmark"])[1]/text()
        return
        <instance>
            { for $key in tokenize($instance/@key, ' ') return <key>{ $key }</key> }
            <title>{ normalize-space($instance/string()) }</title>
            <link>{ concat(
                        '/catalog/', 
                        $roottei/@xml:id/data(), 
                        '|', 
                        $shelfmark,
                        if ($roottei//tei:sourceDesc//tei:surrogates/tei:bibl[@type=('digital-fascimile','digital-facsimile') and @subtype='full']) then
                            ' (Digital images online)'
                        else if ($roottei//tei:sourceDesc//tei:surrogates/tei:bibl[@type=('digital-fascimile','digital-facsimile') and @subtype='partial']) then
                            ' (Selected pages online)'
                        else
                            ''
                    )
            }</link>
            { if ($instance/parent::tei:msItem/@xml:id) then <workid>{ $instance/parent::tei:msItem/@xml:id }</workid> else () }
            <shelfmark>{ $shelfmark }</shelfmark>
        </instance>;

<add>
{
    comment{concat(' Indexing started at ', current-dateTime(), ' using authority file at ', substring-after(base-uri($authorityentries[1]), 'file:'), ' ')}
}
{
    (: Loop thru each entry in the authority file :)
    for $work in $authorityentries

        (: Get info in authority entry :)
        let $id := $work/@xml:id/data()
        let $title := if ($work/tei:title[@type='uniform']) then normalize-space($work/tei:title[@type='uniform'][1]/string()) else normalize-space($work/tei:title[1]/string())
        let $variants := for $v in $work/tei:title[not(@type='uniform')] return normalize-space($v/string())
        let $extrefs := for $r in $work/tei:note[@type='links']//tei:item/tei:ref return concat($r/@target/data(), '|', bod:lookupAuthorityName(normalize-space($r/tei:title/string())))
        let $bibrefs := for $b in $work/tei:bibl return bod:italicizeTitles($b)
        let $notes := for $n in $work/tei:note[not(@type=('links','shelfmark','language','subject'))] return bod:italicizeTitles($n)
        let $subjects := distinct-values($work/tei:note[@type='subject']/string())
        let $lang := $work/tei:textLang
        
        (: Get info in all the instances in the manuscript description files :)
        let $instances := $allinstances[key = $id]

        (: Output a Solr doc element :)
        return if (count($instances) gt 0) then
            <doc>
                <field name="type">work</field>
                <field name="pk">{ $id }</field>
                <field name="id">{ $id }</field>
                <field name="title">{ $title }</field>
                <field name="alpha_title">
                    { 
                    if (contains($title, ':')) then
                        bod:alphabetize($title)
                    else
                        bod:alphabetizeTitle($title)
                    }
                </field>
                {
                for $variant in distinct-values($variants)
                    order by $variant
                    return <field name="wk_variant_sm">{ $variant }</field>
                }
                {
                let $lcvariants := for $variant in ($title, $variants) return lower-case($variant)
                for $instancevariant in distinct-values($instances/title/text())
                    order by $instancevariant
                    return if (not(lower-case($instancevariant) = $lcvariants)) then
                        <field name="wk_variant_sm">{ $instancevariant }</field>
                    else
                        ()
                }
                {
                for $extref in $extrefs
                    order by $extref
                    return <field name="link_external_smni">{ $extref }</field>
                }
                {
                for $bibref in $bibrefs
                    order by $bibref
                    return <field name="bibref_smni">{ $bibref }</field>
                }
                {
                for $note in $notes
                    order by $note
                    return <field name="note_smni">{ $note }</field>
                }
                {
                bod:languages($work/tei:textLang, 'lang_sm')
                }
                {
                for $subject in $subjects
                    return <field name="wk_subjects_sm">{ normalize-space($subject) }</field>
                }
                {
                (: See also links to other entries in the same authority file :)
                let $relatedids := tokenize(translate(string-join(($work/@corresp, $work/@sameAs), ' '), '#', ''), ' ')
                for $relatedid in distinct-values($relatedids)
                    let $url := concat("/catalog/", $relatedid)
                    let $linktext := ($authorityentries[@xml:id = $relatedid]/tei:title[@type = 'uniform'][1])[1]
                    return
                    if (exists($linktext) and $allinstances[key = $relatedid]) then
                        let $link := concat($url, "|", $linktext/string())
                        return
                        <field name="link_related_smni">{ $link }</field>
                    else
                        bod:logging('info', 'Cannot create see-also link', ($id, $relatedid))
                }
                {
                for $link in $links2instances
                    order by $link
                    return <field name="link_manuscripts_smni">{ $link }</field>
                }
            </doc>
        else
            (
            bod:logging('info', 'Skipping work in works.xml as no matching key attribute found', ($id, $title))
            )
}

{
    (: Log instances that haven't (yet) been added to the authority file :)
    for $id in distinct-values($allinstances/@k/data())
        return if (not(some $e in $authorityentries/@xml:id/data() satisfies $e eq $id)) then
            bod:logging('warn', 'Title with key attribute not in works.xml: will create broken link', ($id, $allinstances[@k = $id]/n/text()))
        else
            ()
}

{
    (: Log instances that don't (yet) have a key attribute :)
    for $i in distinct-values($allinstances[not(@k) and child::p]/n/text())
        order by $i
        return bod:logging('info', 'Title without key attribute', $i)
}
</add>